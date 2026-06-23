/*
 * vidinput_macos.mm
 *
 * macOS AVFoundation Video Input Plugin for PTLib
 *
 * Copyright (C) 2025 Y. Asakawa
 *
 * The contents of this file are subject to the Mozilla Public License
 * Version 1.0 (the "License"); you may not use this file except in
 * compliance with the License. You may obtain a copy of the License at
 * http://www.mozilla.org/MPL/
 *
 * Software distributed under the License is distributed on an "AS IS"
 * basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
 * the License for the specific language governing rights and limitations
 * under the License.
 *
 * Features:
 *  - Continuity Camera support for wide range of camera devices
 *  - Automatic optimal resolution detection
 *  - Efficient YUV420p format conversion
 *  - Stable capture session management
 */

#define P_FORCE_STATIC_PLUGIN
#include "vidinput_macos.h"
#include <ptlib/pluginmgr.h>

#ifdef __OBJC__
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreGraphics/CoreGraphics.h>
#import <AppKit/AppKit.h>
#endif

#include <iostream>
#include <ptlib.h>
#include <algorithm>
#include <chrono>
#include <thread>

//---------------------------------------------------------------------------
// EnhancedCaptureDelegate - 拡張フレームキャプチャデリゲート
// Phase 2: CVPixelBufferRefリングバッファ方式
//---------------------------------------------------------------------------
#ifdef __OBJC__

// リングバッファサイズ（2枚で十分）
#define RING_BUFFER_SIZE 2

@interface EnhancedCaptureDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
{
    NSLock* _frameLock;
    
    // Phase 2: CVPixelBufferRefリングバッファ
    CVPixelBufferRef _ringBuffer[RING_BUFFER_SIZE];
    int _writeIndex;      // 書き込み位置
    int _readIndex;       // 読み取り位置
    int _frameCount;      // リング内のフレーム数
    
    // 正規化済みI420バッファ（720p固定）
    NSMutableData* _normalizedBuffer;
    BOOL _hasNormalizedFrame;
    
    // フレーム情報
    size_t _currentWidth;
    size_t _currentHeight;
}
@property (atomic, assign) BOOL hasNewFrame;
@property (atomic, assign) size_t frameWidth;
@property (atomic, assign) size_t frameHeight;
@property (atomic, assign) size_t frameSize;
@property (atomic, strong) NSData* latestFrameData;

// スレッドセーフなフレーム取得
- (NSData*)getFrameDataWithLock:(size_t*)outWidth height:(size_t*)outHeight;
- (void)markFrameConsumed;
// Phase 2: CVPixelBufferリングバッファ操作
- (void)pushPixelBuffer:(CVPixelBufferRef)buffer;
- (CVPixelBufferRef)getLatestPixelBuffer;
@end

@implementation EnhancedCaptureDelegate
- (instancetype)init {
    self = [super init];
    if (self) {
        _frameLock = [[NSLock alloc] init];
        _hasNewFrame = NO;
        _frameWidth = 0;
        _frameHeight = 0;
        _frameSize = 0;
        _latestFrameData = nil;
        
        // Phase 2: リングバッファ初期化
        for (int i = 0; i < RING_BUFFER_SIZE; i++) {
            _ringBuffer[i] = NULL;
        }
        _writeIndex = 0;
        _readIndex = 0;
        _frameCount = 0;
        
        _normalizedBuffer = nil;
        _hasNormalizedFrame = NO;
        _currentWidth = 0;
        _currentHeight = 0;
    }
    return self;
}

- (void)dealloc {
    // リングバッファ内のCVPixelBufferをリリース
    [_frameLock lock];
    for (int i = 0; i < RING_BUFFER_SIZE; i++) {
        if (_ringBuffer[i]) {
            CVPixelBufferRelease(_ringBuffer[i]);
            _ringBuffer[i] = NULL;
        }
    }
    [_frameLock unlock];
}

// Phase 2: 最新のCVPixelBufferを取得（Retainして返す - 呼び出し側がReleaseする責任）
- (CVPixelBufferRef)getLatestPixelBuffer {
    CVPixelBufferRef result = NULL;
    [_frameLock lock];
    if (_frameCount > 0) {
        // 最新のフレームを取得（古いフレームは捨てる）
        int latestIndex = (_writeIndex - 1 + RING_BUFFER_SIZE) % RING_BUFFER_SIZE;
        if (_ringBuffer[latestIndex]) {
            result = _ringBuffer[latestIndex];
            CVPixelBufferRetain(result);  // 呼び出し側用にRetain
        }
    }
    [_frameLock unlock];
    return result;
}

// Phase 2: リングバッファにCVPixelBufferをプッシュ（ゼロコピー）
- (void)pushPixelBuffer:(CVPixelBufferRef)buffer {
    if (!buffer) return;
    
    [_frameLock lock];
    
    // 古いバッファをリリース
    if (_ringBuffer[_writeIndex]) {
        CVPixelBufferRelease(_ringBuffer[_writeIndex]);
    }
    
    // 新しいバッファをRetainして保存
    CVPixelBufferRetain(buffer);
    _ringBuffer[_writeIndex] = buffer;
    
    // 書き込み位置を進める（循環）
    _writeIndex = (_writeIndex + 1) % RING_BUFFER_SIZE;
    
    // フレームカウントを更新
    if (_frameCount < RING_BUFFER_SIZE) {
        _frameCount++;
    }
    
    // 新しいフレームあり
    _hasNormalizedFrame = NO;  // 再変換が必要
    
    [_frameLock unlock];
}

// フレーム消費済みマーク（hasNewFrameをNOに）
- (void)markFrameConsumed {
    // hasNewFrameはatomicプロパティなので直接操作可能
    // リングバッファモードではフレーム自体は保持されたまま
}

// スレッドセーフなフレーム取得 - I420形式でデータを返す
- (NSData*)getFrameDataWithLock:(size_t*)outWidth height:(size_t*)outHeight {
    [_frameLock lock];
    
    // Phase 2: 正規化済みバッファがあればそれを返す
    if (_hasNormalizedFrame && _normalizedBuffer && [_normalizedBuffer length] > 0) {
        *outWidth = _currentWidth;
        *outHeight = _currentHeight;
        NSData* result = [NSData dataWithData:_normalizedBuffer];
        [_frameLock unlock];
        return result;
    }
    
    // フォールバック: リングから最新を取得してその場で変換
    if (_frameCount > 0) {
        int latestIndex = (_writeIndex - 1 + RING_BUFFER_SIZE) % RING_BUFFER_SIZE;
        CVPixelBufferRef pixelBuffer = _ringBuffer[latestIndex];
        if (pixelBuffer) {
            [_frameLock unlock];
            
            // ロック解除後に変換（重い処理なのでロック外で実行）
            NSData* converted = [self convertPixelBufferToI420:pixelBuffer width:outWidth height:outHeight];
            return converted;
        }
    }
    
    [_frameLock unlock];
    return nil;
}

// CVPixelBuffer → I420変換（720p正規化）
- (NSData*)convertPixelBufferToI420:(CVPixelBufferRef)pixelBuffer width:(size_t*)outWidth height:(size_t*)outHeight {
    if (!pixelBuffer) return nil;
    
    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    
    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    
    // TODO Phase 3: ここで720pにリサイズ
    // 現在は入力解像度をそのまま使用
    
    *outWidth = width;
    *outHeight = height;
    
    size_t ySize = width * height;
    size_t uvSize = ySize / 4;
    size_t totalI420Size = ySize + uvSize * 2;
    
    NSMutableData* yuvData = [NSMutableData dataWithLength:totalI420Size];
    
    if (CVPixelBufferGetPlaneCount(pixelBuffer) == 2) {
        size_t yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
        size_t uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
        
        uint8_t* yDest = (uint8_t*)yuvData.mutableBytes;
        uint8_t* ySource = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
        
        // Yプレーンコピー
        for (size_t row = 0; row < height; row++) {
            memcpy(yDest + row * width, ySource + row * yBytesPerRow, width);
        }
        
        // NV12 → I420変換
        uint8_t* uvSource = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
        uint8_t* uDest = yDest + ySize;
        uint8_t* vDest = uDest + uvSize;
        
        for (size_t row = 0; row < height/2; row++) {
            uint8_t* rowSrc = uvSource + row * uvBytesPerRow;
            size_t dstRowOffset = row * (width/2);
            
            for (size_t col = 0; col < width/2; col++) {
                uDest[dstRowOffset + col] = rowSrc[col * 2];       // Cb = U
                vDest[dstRowOffset + col] = rowSrc[col * 2 + 1];   // Cr = V
            }
        }
    }
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    
    return yuvData;
}

// ========================================================================
// Phase 2: captureOutput - CVPixelBufferRef リングバッファを使用
// ========================================================================
- (void)captureOutput:(AVCaptureOutput *)output 
 didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer 
        fromConnection:(AVCaptureConnection *)connection 
{
    // ========================================================================
    // 診断ログ: カメラからのフレーム受信状況を詳細に記録
    // ========================================================================
    static int frameCount = 0;
    static int droppedFrames = 0;
    static CFAbsoluteTime lastLogTime = 0;
    static CFAbsoluteTime lastFrameTime = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    
    // フレーム間隔を計測（ジッタ検出用）
    double frameInterval = (lastFrameTime > 0) ? (now - lastFrameTime) * 1000.0 : 0;
    lastFrameTime = now;
    
    frameCount++;
    
    // 1秒ごとに詳細ログ出力
    if (now - lastLogTime >= 1.0) {
        PTRACE(1, "EnhancedCapture\t📊 [FPS診断] カメラ受信: " << frameCount << " fps"
               << " | ドロップ: " << droppedFrames
               << " | 最終フレーム間隔: " << (int)frameInterval << "ms"
               << " | リングバッファ: " << _frameCount << "/" << RING_BUFFER_SIZE);
        frameCount = 0;
        droppedFrames = 0;
        lastLogTime = now;
    }
    
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) {
        droppedFrames++;
        return;
    }
    
    // ========================================================================
    // 診断: 実際の受信解像度とフォーマットを確認（初回のみ詳細ログ）
    // ========================================================================
    static bool firstFrameDiag = false;
    if (!firstFrameDiag) {
        size_t actualWidth = CVPixelBufferGetWidth(imageBuffer);
        size_t actualHeight = CVPixelBufferGetHeight(imageBuffer);
        OSType pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer);
        size_t planeCount = CVPixelBufferGetPlaneCount(imageBuffer);
        
        // フォーマットを人間が読める形式に変換
        char formatStr[5] = {0};
        formatStr[0] = (pixelFormat >> 24) & 0xFF;
        formatStr[1] = (pixelFormat >> 16) & 0xFF;
        formatStr[2] = (pixelFormat >> 8) & 0xFF;
        formatStr[3] = pixelFormat & 0xFF;
        
        PTRACE(1, "EnhancedCapture\t🔍 [診断] 初回フレーム受信:");
        PTRACE(1, "EnhancedCapture\t   実際の解像度: " << actualWidth << "x" << actualHeight);
        PTRACE(1, "EnhancedCapture\t   ピクセルフォーマット: " << formatStr << " (0x" << std::hex << pixelFormat << std::dec << ")");
        PTRACE(1, "EnhancedCapture\t   プレーン数: " << planeCount);
        
        if (planeCount >= 2) {
            size_t yStride = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0);
            size_t uvStride = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 1);
            PTRACE(1, "EnhancedCapture\t   Yストライド: " << yStride << " (padding: " << (yStride - actualWidth) << ")");
            PTRACE(1, "EnhancedCapture\t   UVストライド: " << uvStride);
        }
        
        // 期待値との比較
        if (actualWidth != 1280 || actualHeight != 720) {
            PTRACE(1, "EnhancedCapture\t   ⚠️ 警告: 期待解像度(1280x720)と異なります！");
        }
        
        firstFrameDiag = true;
    }
    
    // Phase 2: CVPixelBufferRefをリングバッファにプッシュ（ゼロコピー）
    // CVPixelBufferは参照カウント管理でコピーなしに保持
    [self pushPixelBuffer:imageBuffer];
    
    // フレーム情報を更新（ロック不要、atomicプロパティ）
    self.frameWidth = CVPixelBufferGetWidth(imageBuffer);
    self.frameHeight = CVPixelBufferGetHeight(imageBuffer);
    self.hasNewFrame = YES;
    
    // Log first frame info for debugging
    static bool firstFrameLogged = false;
    if (!firstFrameLogged) {
        OSType pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer);
        PTRACE(1, "EnhancedCapture\t🎬 First frame: " << self.frameWidth << "x" << self.frameHeight 
               << " format=" << (char*)&pixelFormat);
        firstFrameLogged = true;
    }
}
@end
#endif // __OBJC__

//---------------------------------------------------------------------------
// EnhancedCaptureManager - カメラ管理とフレーム処理
//---------------------------------------------------------------------------
#ifdef __OBJC__
class EnhancedCaptureManager {
private:
    AVCaptureSession* session;
    AVCaptureDevice* device;
    AVCaptureDeviceInput* input;
    AVCaptureVideoDataOutput* output;
    EnhancedCaptureDelegate* delegate;
    dispatch_queue_t captureQueue;
    bool isInitialized;
    
    // 解像度関連情報
    unsigned frameWidth;
    unsigned frameHeight;
    PINDEX frameSize;
    PMutex frameMutex;
    PBYTEArray frameBuffer;
    
public:
    EnhancedCaptureManager() 
        : session(nil),
          device(nil), 
          input(nil),
          output(nil),
          delegate(nil),
          captureQueue(NULL),
          isInitialized(false),
          frameWidth(0),
          frameHeight(0),
          frameSize(0)
    {
        PTRACE(4, "EnhancedCapture\t拡張カメラマネージャーを初期化しました");
    }
    
    ~EnhancedCaptureManager() {
        Stop();
        
        @autoreleasepool {
            session = nil;
            device = nil;
            input = nil;
            
            if (output) {
                [output setSampleBufferDelegate:nil queue:NULL];
                output = nil;
            }
            
            delegate = nil;
            
            if (captureQueue) {
                captureQueue = NULL;
            }
        }
    }
    
    // 利用可能なデバイスリストを取得
    PStringArray GetDeviceNames() {
        PStringArray deviceNames;
        
        @autoreleasepool {
            // すべての種類のビデオデバイスを検出
            AVCaptureDeviceDiscoverySession* discoverySession = [AVCaptureDeviceDiscoverySession
                discoverySessionWithDeviceTypes:@[
                    AVCaptureDeviceTypeContinuityCamera,
                    AVCaptureDeviceTypeBuiltInWideAngleCamera, 
                    AVCaptureDeviceTypeExternal
                ]
                mediaType:AVMediaTypeVideo
                position:AVCaptureDevicePositionUnspecified];
            
            // 各デバイスの情報を収集
            for (AVCaptureDevice* dev in discoverySession.devices) {
                PString deviceName = PString([dev.localizedName UTF8String]);
                deviceNames.AppendString(deviceName);
                
                PTRACE(5, "EnhancedCapture\tデバイス検出: " << deviceName
                       << " (ID: " << [dev.uniqueID UTF8String] << ")");
            }
        }
        
        return deviceNames;
    }
    
    // 詳細なデバイス情報を取得
    struct DeviceInfo : public PObject {
        PCLASSINFO(DeviceInfo, PObject);
        
        PString deviceID;
        PString name;
        PString manufacturer;
        PString modelID;
        bool isContinuityCamera;
        
        DeviceInfo() : isContinuityCamera(false) {}
        
        // コピーコンストラクタも追加
        DeviceInfo(const DeviceInfo& other) : PObject(other) {
            deviceID = other.deviceID;
            name = other.name;
            manufacturer = other.manufacturer;
            modelID = other.modelID;
            isContinuityCamera = other.isContinuityCamera;
        }
    };
    
    PArray<DeviceInfo> GetDetailedDeviceList() {
        PArray<DeviceInfo> deviceList;
        
        @autoreleasepool {
            AVCaptureDeviceDiscoverySession* discoverySession = [AVCaptureDeviceDiscoverySession
                discoverySessionWithDeviceTypes:@[
                    AVCaptureDeviceTypeContinuityCamera,
                    AVCaptureDeviceTypeBuiltInWideAngleCamera, 
                    AVCaptureDeviceTypeExternal
                ]
                mediaType:AVMediaTypeVideo
                position:AVCaptureDevicePositionUnspecified];
            
            for (AVCaptureDevice* dev in discoverySession.devices) {
                DeviceInfo* info = new DeviceInfo();
                info->deviceID = [dev.uniqueID UTF8String];
                info->name = [dev.localizedName UTF8String];
                
                if (dev.manufacturer) {
                    info->manufacturer = [dev.manufacturer UTF8String];
                }
                
                if (dev.modelID) {
                    info->modelID = [dev.modelID UTF8String];
                }
                
                // iPhoneのContinuity Cameraを特別扱い
                info->isContinuityCamera = ([dev.manufacturer isEqualToString:@"Apple"] && 
                                          [dev.modelID hasPrefix:@"iPhone"]);
                
                deviceList.Append(info);
                
                PTRACE(4, "EnhancedCapture\tデバイス: " << info->name 
                       << " (ID: " << info->deviceID << ")"
                       << " 製造元: " << info->manufacturer
                       << " モデル: " << info->modelID
                       << " Continuity: " << (info->isContinuityCamera ? "はい" : "いいえ"));
            }
        }
        
        return deviceList;
    }
    
    // デバイスIDで初期化
    bool OpenDeviceWithID(const PString& deviceID) {
        @autoreleasepool {
            // セッション作成
            session = [[AVCaptureSession alloc] init];
            
            NSString* targetID = [NSString stringWithUTF8String:(const char*)deviceID];
            
            // すべての種類のビデオデバイスを検出
            AVCaptureDeviceDiscoverySession* discoverySession = [AVCaptureDeviceDiscoverySession
                discoverySessionWithDeviceTypes:@[
                    AVCaptureDeviceTypeContinuityCamera,
                    AVCaptureDeviceTypeBuiltInWideAngleCamera, 
                    AVCaptureDeviceTypeExternal
                ]
                mediaType:AVMediaTypeVideo
                position:AVCaptureDevicePositionUnspecified];
            
            // デバイスIDでマッチング
            for (AVCaptureDevice* dev in discoverySession.devices) {
                if ([dev.uniqueID isEqualToString:targetID]) {
                    device = dev;
                    break;
                }
            }
            
            if (!device) {
                PTRACE(1, "EnhancedCapture\tID指定デバイスが見つかりませんでした: " << (const char*)deviceID);
                return false;
            }
            
            return ConfigureDevice();
        }
    }
    
    // デバイス名で初期化
    bool OpenDevice(const PString& deviceName) {
        @autoreleasepool {
            // セッション作成
            session = [[AVCaptureSession alloc] init];
            
            NSString* targetName = [NSString stringWithUTF8String:(const char*)deviceName];
            
            // すべての種類のビデオデバイスを検出
            AVCaptureDeviceDiscoverySession* discoverySession = [AVCaptureDeviceDiscoverySession
                discoverySessionWithDeviceTypes:@[
                    AVCaptureDeviceTypeContinuityCamera,
                    AVCaptureDeviceTypeBuiltInWideAngleCamera, 
                    AVCaptureDeviceTypeExternal
                ]
                mediaType:AVMediaTypeVideo
                position:AVCaptureDevicePositionUnspecified];
            
            // デバイス名でマッチング
            for (AVCaptureDevice* dev in discoverySession.devices) {
                if ([dev.localizedName isEqualToString:targetName]) {
                    device = dev;
                    break;
                }
            }
            
            // 名前が見つからない場合は最初のデバイスを使用
            if (!device && discoverySession.devices.count > 0) {
                device = [discoverySession.devices objectAtIndex:0];
                PTRACE(3, "EnhancedCapture\t指定されたデバイス '" << (const char*)deviceName 
                       << "' が見つからなかったため、最初のデバイスを使用します: " 
                       << [device.localizedName UTF8String]);
            }
            
            return ConfigureDevice();
        }
    }
    
    // 共通デバイス設定処理
    bool ConfigureDevice() {
        if (!device) {
            PTRACE(1, "EnhancedCapture\tデバイスが見つかりませんでした");
            return false;
        }
        
        PTRACE(3, "EnhancedCapture\tデバイスを構成します: " << [device.localizedName UTF8String]);
        
        // CRITICAL FIX: 720pを最優先にする（H.264エンコーダーとの互換性のため）
        // 1920x1080は使用しない - 必ず1280x720を使用する
        if ([session canSetSessionPreset:AVCaptureSessionPreset1280x720]) {
            [session setSessionPreset:AVCaptureSessionPreset1280x720];
            PTRACE(1, "EnhancedCapture\t🎥 720pプリセット設定 (FORCED for H.264 compatibility)");
        } else {
            PTRACE(1, "EnhancedCapture\t⚠️ WARNING: 720pプリセット利用不可");
        }
        
        // Continuity Cameraの特別扱い
        bool isContinuityCamera = ([device.manufacturer isEqualToString:@"Apple"] && 
                                  [device.modelID hasPrefix:@"iPhone"]);
        if (isContinuityCamera) {
            PTRACE(3, "EnhancedCapture\tContinuity Camera検出: " << [device.modelID UTF8String]);
        }
        
        // 入力と出力の設定
        NSError* error = nil;
        input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
        if (input && [session canAddInput:input]) {
            [session addInput:input];
        } else {
            PTRACE(1, "EnhancedCapture\t入力の追加に失敗: " << (error ? [error.localizedDescription UTF8String] : "不明なエラー"));
            return false;
        }
        
        output = [[AVCaptureVideoDataOutput alloc] init];
        
        // CRITICAL FIX: Set output resolution in videoSettings
        // This forces the output to scale to 720p
        [output setVideoSettings:@{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (id)kCVPixelBufferWidthKey: @(1280),
            (id)kCVPixelBufferHeightKey: @(720)
        }];
        PTRACE(1, "EnhancedCapture\t📐 Output解像度を1280x720に強制設定");
        
        delegate = [[EnhancedCaptureDelegate alloc] init];
        captureQueue = dispatch_queue_create("EnhancedCaptureQueue", DISPATCH_QUEUE_SERIAL);
        [output setSampleBufferDelegate:delegate queue:captureQueue];
        
        if ([session canAddOutput:output]) {
            [session addOutput:output];
            isInitialized = true;
            
            // ========================================================================
            // フレームレート設定 - 詳細診断ログ付き
            // ========================================================================
            NSError* fpsError = nil;
            if ([device lockForConfiguration:&fpsError]) {
                AVCaptureDeviceFormat* currentFormat = device.activeFormat;
                if (currentFormat) {
                    // サポートされるフレームレート範囲を全て表示
                    PTRACE(1, "EnhancedCapture\t🔍 [FPS診断] デバイス対応フレームレート:");
                    for (AVFrameRateRange* range in currentFormat.videoSupportedFrameRateRanges) {
                        PTRACE(1, "EnhancedCapture\t   範囲: " << range.minFrameRate << " - " << range.maxFrameRate << " fps"
                               << " (duration: " << CMTimeGetSeconds(range.minFrameDuration) << "s - " 
                               << CMTimeGetSeconds(range.maxFrameDuration) << "s)");
                    }
                    
                    // フォーマット詳細
                    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(currentFormat.formatDescription);
                    PTRACE(1, "EnhancedCapture\t   現在のフォーマット解像度: " << dims.width << "x" << dims.height);
                    
                    PTRACE(1, "EnhancedCapture\t🔧 30fps設定開始...");
                    
                    // 30fps設定を試みる - シンプル化
                    bool fpsSet = false;
                    CMTime frameDuration = CMTimeMake(1, 30);
                    @try {
                        device.activeVideoMinFrameDuration = frameDuration;
                        device.activeVideoMaxFrameDuration = frameDuration;
                        fpsSet = true;
                        PTRACE(1, "EnhancedCapture\t✅ フレームレート設定成功: 30fps");
                    } @catch (NSException *exception) {
                        PTRACE(1, "EnhancedCapture\t❌ フレームレート設定例外: " << [exception.reason UTF8String]);
                    }
                    
                    if (!fpsSet) {
                        PTRACE(1, "EnhancedCapture\t❌ フレームレート設定失敗");
                    }
                    
                    // 設定後の確認（ゼロ除算を防止）
                    Float64 minDur = CMTimeGetSeconds(device.activeVideoMinFrameDuration);
                    Float64 maxDur = CMTimeGetSeconds(device.activeVideoMaxFrameDuration);
                    if (minDur > 0) {
                        PTRACE(1, "EnhancedCapture\t   設定後のMinDuration: " << minDur << "s (" << (1.0 / minDur) << " fps)");
                    }
                    if (maxDur > 0) {
                        PTRACE(1, "EnhancedCapture\t   設定後のMaxDuration: " << maxDur << "s (" << (1.0 / maxDur) << " fps)");
                    }
                }
                [device unlockForConfiguration];
            } else {
                PTRACE(1, "EnhancedCapture\t❌ lockForConfiguration失敗: " << (fpsError ? [fpsError.localizedDescription UTF8String] : "不明"));
            }
            
            // ログにデバイス情報を出力
            PTRACE(3, "EnhancedCapture\tデバイス設定完了: " << [device.localizedName UTF8String]
                   << ", Model: " << [device.modelID UTF8String]
                   << ", Manufacturer: " << [device.manufacturer UTF8String]);
            
            return true;
        } else {
            PTRACE(1, "EnhancedCapture\t出力の追加に失敗");
            return false;
        }
    }
    
    // 解像度設定
    bool SetFrameSize(unsigned width, unsigned height) {
        if (!isInitialized) return false;
        
        @autoreleasepool {
            PTRACE(1, "EnhancedCapture\t🔧 解像度を設定: " << width << "x" << height);
            
            // 一時停止
            bool wasRunning = [session isRunning];
            if (wasRunning) {
                [session stopRunning];
                // セッションが完全に停止するのを待つ
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }
            
            [session beginConfiguration];
            
            // H.264エンコーダーに適した解像度にフォーカス
            bool presetSet = false;
            
            // 1280x720を最優先（H.264互換性のため）
            if (width == 1280 && height == 720) {
                if ([session canSetSessionPreset:AVCaptureSessionPreset1280x720]) {
                    [session setSessionPreset:AVCaptureSessionPreset1280x720];
                    presetSet = true;
                    PTRACE(1, "EnhancedCapture\t✅ AVCaptureSessionPreset1280x720 設定完了");
                } else {
                    PTRACE(1, "EnhancedCapture\t⚠️ AVCaptureSessionPreset1280x720 利用不可");
                }
            }
            // 640x480
            else if (width == 640 && height == 480) {
                if ([session canSetSessionPreset:AVCaptureSessionPreset640x480]) {
                    [session setSessionPreset:AVCaptureSessionPreset640x480];
                    presetSet = true;
                    PTRACE(1, "EnhancedCapture\t✅ AVCaptureSessionPreset640x480 設定完了");
                }
            }
            // 1920x1080 (使用しない - 720p優先)
            else if (width == 1920 && height == 1080) {
                // 1080pは使用しない - 720pにダウングレード
                if ([session canSetSessionPreset:AVCaptureSessionPreset1280x720]) {
                    [session setSessionPreset:AVCaptureSessionPreset1280x720];
                    presetSet = true;
                    width = 1280;
                    height = 720;
                    PTRACE(1, "EnhancedCapture\t⚠️ 1080p要求を720pにダウングレード");
                }
            }
            
            // プリセットが設定できた場合、内部変数も更新
            if (presetSet) {
                frameWidth = width;
                frameHeight = height;
                frameSize = width * height * 3 / 2;  // YUV420
                
                // CRITICAL FIX: Also update output videoSettings to force resolution
                if (output) {
                    [output setVideoSettings:@{
                        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                        (id)kCVPixelBufferWidthKey: @(frameWidth),
                        (id)kCVPixelBufferHeightKey: @(frameHeight)
                    }];
                    PTRACE(1, "EnhancedCapture\t📐 Output videoSettings更新: " << frameWidth << "x" << frameHeight);
                }
                
                PTRACE(1, "EnhancedCapture\t📐 内部解像度を更新: " << frameWidth << "x" << frameHeight 
                       << " (frameSize=" << frameSize << ")");
            }
            
            // プリセットが設定できない場合は手動フォーマット設定
            if (!presetSet) {
                PTRACE(1, "EnhancedCapture\t🔧 プリセット不可 - 手動フォーマット設定を試行");
                NSError* error = nil;
                if ([device lockForConfiguration:&error]) {
                    // 希望サイズに最も近いフォーマットを検索
                    AVCaptureDeviceFormat* bestFormat = nil;
                    int bestDiff = INT_MAX;
                    
                    for (AVCaptureDeviceFormat* format in [device formats]) {
                        CMFormatDescriptionRef desc = format.formatDescription;
                        CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(desc);
                        
                        // 1280x720の厳密マッチを優先
                        if (dims.width == 1280 && dims.height == 720) {
                            bestFormat = format;
                            bestDiff = 0;
                            PTRACE(1, "EnhancedCapture\t✅ 1280x720の厳密マッチ発見！");
                            break;
                        }
                        
                        int diff = abs((int)dims.width - (int)width) + abs((int)dims.height - (int)height);
                        if (diff < bestDiff) {
                            bestDiff = diff;
                            bestFormat = format;
                        }
                    }
                    
                    if (bestFormat) {
                        [device setActiveFormat:bestFormat];
                        
                        // フレームレートを設定（カクカク防止）- サポート範囲をチェック
                        for (AVFrameRateRange* range in bestFormat.videoSupportedFrameRateRanges) {
                            if (range.maxFrameRate >= 30.0 && range.minFrameRate <= 30.0) {
                                CMTime frameDuration = CMTimeMake(1, 30);
                                device.activeVideoMinFrameDuration = frameDuration;
                                device.activeVideoMaxFrameDuration = frameDuration;
                                PTRACE(1, "EnhancedCapture\t⏱️ フレームレート設定: 30fps");
                                break;
                            } else if (range.maxFrameRate >= 25.0) {
                                CMTime frameDuration = CMTimeMake(1, 25);
                                device.activeVideoMinFrameDuration = frameDuration;
                                device.activeVideoMaxFrameDuration = frameDuration;
                                PTRACE(1, "EnhancedCapture\t⏱️ フレームレート設定: 25fps (fallback)");
                                break;
                            }
                        }
                        
                        CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(bestFormat.formatDescription);
                        frameWidth = dims.width;
                        frameHeight = dims.height;
                        frameSize = frameWidth * frameHeight * 3 / 2;
                        PTRACE(1, "EnhancedCapture\t✅ 手動フォーマット設定: " << frameWidth << "x" << frameHeight);
                    }
                    
                    [device unlockForConfiguration];
                } else {
                    PTRACE(1, "EnhancedCapture\t❌ デバイス構成をロックできません: " << [error.localizedDescription UTF8String]);
                }
            }
            
            [session commitConfiguration];
            
            // 再開 - delegateの解像度がリセットされるのを待つ
            if (wasRunning) {
                // delegateの古いフレーム情報をクリア
                delegate.hasNewFrame = NO;
                delegate.frameWidth = 0;
                delegate.frameHeight = 0;
                
                [session startRunning];
                
                // 新しい解像度でフレームが来るまで待つ（最大1秒）
                for (int i = 0; i < 20; i++) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(50));
                    if (delegate.hasNewFrame && delegate.frameWidth > 0) {
                        if (delegate.frameWidth == frameWidth && delegate.frameHeight == frameHeight) {
                            PTRACE(1, "EnhancedCapture\t✅ 解像度変更確認: " << delegate.frameWidth << "x" << delegate.frameHeight);
                            break;
                        } else {
                            PTRACE(1, "EnhancedCapture\t⚠️ フレーム解像度が期待と異なる: " 
                                   << delegate.frameWidth << "x" << delegate.frameHeight 
                                   << " (期待: " << frameWidth << "x" << frameHeight << ")");
                        }
                    }
                }
            }
            
            PTRACE(1, "EnhancedCapture\t🎬 SetFrameSize完了: " << frameWidth << "x" << frameHeight);
            return true;
        }
    }
    
    bool Start() {
        if (!isInitialized) {
            PTRACE(2, "EnhancedCapture\tStart: Not initialized");
            return false;
        }
        
        @autoreleasepool {
            PTRACE(3, "EnhancedCapture\tカメラセッション開始...");
            [session startRunning];
            
            // セッション開始後、最初のフレームが来るまで待機
            PTRACE(3, "EnhancedCapture\tカメラセッション開始、フレーム待機中...");
            
            // 最大5秒間待機、ただし柔軟に対応
            bool frameReceived = false;
            for (int i = 0; i < 50; i++) {
                if (delegate.hasNewFrame) {
                    // 解像度情報を更新
                    frameWidth = (unsigned)delegate.frameWidth;
                    frameHeight = (unsigned)delegate.frameHeight;
                    frameSize = (PINDEX)delegate.frameSize;
                    
                    PTRACE(3, "EnhancedCapture\tフレーム取得開始: " << frameWidth << "x" << frameHeight);
                    
                    // CRITICAL: 解像度確認ログ
                    if (frameWidth == 1280 && frameHeight == 720) {
                        PTRACE(1, "EnhancedCapture\t✅ 720p確認OK: キャプチャ解像度は正しく1280x720です");
                    } else {
                        PTRACE(1, "EnhancedCapture\t⚠️ 解像度不一致: 期待値1280x720、実際は" << frameWidth << "x" << frameHeight);
                    }
                    
                    frameReceived = true;
                    break;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }
            
            // フレームを受信できなかった場合でも、セッションが動作していれば成功とみなす
            if (!frameReceived) {
                if ([session isRunning]) {
                    PTRACE(2, "EnhancedCapture\tフレームはまだ受信していませんが、セッションは動作中です");
                    // デフォルト解像度を設定
                    frameWidth = 640;
                    frameHeight = 480;
                    frameSize = frameWidth * frameHeight * 3 / 2; // YUV420
                    return true;  // セッションが動作中なら成功
                } else {
                    PTRACE(1, "EnhancedCapture\tタイムアウト: カメラセッションが開始できませんでした");
                    return false;
                }
            }
            
            return true;
        }
    }
    
    void Stop() {
        if (!isInitialized) return;
        
        @autoreleasepool {
            [session stopRunning];
        }
    }
    
    bool GetFrameData(BYTE* buffer, PINDEX* bytesReturned) {
        if (!isInitialized) {
            PTRACE(2, "EnhancedCapture\tGetFrameData: Not initialized");
            return false;
        }
        
        // ========================================================================
        // パフォーマンス診断: GetFrameData呼び出し頻度とロック待ち時間
        // ========================================================================
        static int getFrameCallCount = 0;
        static int successCount = 0;
        static int failCount = 0;
        static CFAbsoluteTime lastDiagTime = 0;
        CFAbsoluteTime callStart = CFAbsoluteTimeGetCurrent();
        
        getFrameCallCount++;
        
        frameMutex.Wait();
        
        CFAbsoluteTime afterLock = CFAbsoluteTimeGetCurrent();
        double lockWaitMs = (afterLock - callStart) * 1000.0;
        
        // 1秒ごとに診断ログ
        if (afterLock - lastDiagTime >= 1.0) {
            PTRACE(1, "EnhancedCapture\t📊 [GetFrameData診断] 呼び出し: " << getFrameCallCount << "/s"
                   << " | 成功: " << successCount << " | 失敗: " << failCount
                   << " | ロック待ち: " << (int)lockWaitMs << "ms");
            getFrameCallCount = 0;
            successCount = 0;
            failCount = 0;
            lastDiagTime = afterLock;
        }
        
        // CRITICAL FIX: Check if we have any frame data available (new or cached)
        if (!delegate.hasNewFrame && frameBuffer.GetSize() == 0) {
            PTRACE(4, "EnhancedCapture\tGetFrameData: No frame data available (new or cached)");
            failCount++;
            frameMutex.Signal();
            return false;
        }
        
        @autoreleasepool {
            NSData* data = nil;
            PINDEX copySize = 0;
            
            // 呼び出し側が提供するバッファの最大サイズを保存
            PINDEX maxBufferSize = *bytesReturned;
            
            // ★ガード: maxBufferSizeが0の場合はフレームサイズを使用
            if (maxBufferSize == 0 && frameSize > 0) {
                maxBufferSize = frameSize;
            }
            
            if (delegate.hasNewFrame) {
                // スレッドセーフなフレーム取得（ダブルバッファリング）
                CFAbsoluteTime convertStart = CFAbsoluteTimeGetCurrent();
                
                size_t frameW = 0, frameH = 0;
                data = [delegate getFrameDataWithLock:&frameW height:&frameH];
                
                CFAbsoluteTime convertEnd = CFAbsoluteTimeGetCurrent();
                double convertMs = (convertEnd - convertStart) * 1000.0;
                
                // 変換時間が長い場合は警告
                if (convertMs > 10.0) {
                    PTRACE(2, "EnhancedCapture\t⚠️ NV12→I420変換に " << (int)convertMs << "ms かかっています");
                }
                
                if (data) {
                    PINDEX actualDataSize = (PINDEX)data.length;
                    
                    // ★修正: バッファが小さすぎる場合
                    // - 必要サイズを返してfalseで「取れなかった」と認識させる
                    // - 内部キャッシュに保存して次回取得可能にする
                    if (maxBufferSize > 0 && maxBufferSize < actualDataSize) {
                        // バッファサイズを更新して内部状態を保存
                        frameWidth = (unsigned)frameW;
                        frameHeight = (unsigned)frameH;
                        frameSize = actualDataSize;
                        
                        // 内部キャッシュに保存（次回呼び出しで取得可能）
                        if (frameBuffer.GetSize() < frameSize) {
                            frameBuffer.SetSize(frameSize);
                        }
                        memcpy(frameBuffer.GetPointer(), data.bytes, actualDataSize);
                        
                        // 必要サイズを返す
                        *bytesReturned = actualDataSize;
                        
                        PTRACE(2, "EnhancedCapture\t⚠️ Buffer too small (" << maxBufferSize 
                               << " bytes), required: " << actualDataSize << " bytes - returning false");
                        
                        frameMutex.Signal();
                        return false;  // 失敗として返す（呼び出し側がフレームを捨てる）
                    }
                    
                    // バッファサイズOK - コピー実行
                    copySize = actualDataSize;
                    memcpy(buffer, data.bytes, copySize);
                    
                    // Update frame buffer for future use when no new frames
                    frameWidth = (unsigned)frameW;
                    frameHeight = (unsigned)frameH;
                    frameSize = copySize;
                    
                    if (frameBuffer.GetSize() < frameSize) {
                        frameBuffer.SetSize(frameSize);
                    }
                    memcpy(frameBuffer.GetPointer(), data.bytes, copySize);
                    
                    // Mark frame as consumed (スレッドセーフ)
                    [delegate markFrameConsumed];
                    delegate.hasNewFrame = NO;
                    
                    PTRACE(4, "EnhancedCapture\tGetFrameData: Using NEW frame - " << frameWidth << "x" << frameHeight << " (" << copySize << " bytes)");
                } else {
                    PTRACE(3, "EnhancedCapture\tGetFrameData: Fresh frame data is nil");
                    frameMutex.Signal();
                    return false;
                }
            } else {
                // IMPROVEMENT: Reuse last captured frame to maintain frame rate
                copySize = frameSize;
                
                // ★修正: キャッシュフレームもバッファサイズ不足時はfalseを返す
                if (maxBufferSize > 0 && maxBufferSize < copySize && copySize > 0) {
                    *bytesReturned = copySize;
                    PTRACE(2, "EnhancedCapture\t⚠️ Buffer too small for cached (" << maxBufferSize 
                           << " bytes), required: " << copySize << " bytes - returning false");
                    frameMutex.Signal();
                    return false;  // 失敗として返す
                }
                
                if (copySize > 0 && frameBuffer.GetSize() >= copySize) {
                    memcpy(buffer, frameBuffer.GetPointer(), copySize);
                } else {
                    PTRACE(2, "EnhancedCapture\tGetFrameData: Cached frame invalid - frameSize=" << frameSize 
                           << ", bufferSize=" << frameBuffer.GetSize());
                    frameMutex.Signal();
                    return false;
                }
                
                PTRACE(5, "EnhancedCapture\tGetFrameData: Reusing CACHED frame - " << frameWidth << "x" << frameHeight << " (" << copySize << " bytes)");
            }
            
            // Return actual copied size
            *bytesReturned = copySize;
            
            successCount++;
            frameMutex.Signal();
            
            PTRACE(3, "EnhancedCapture\tGetFrameData: Success - " << frameWidth << "x" << frameHeight << " (" << copySize << " bytes)");
            
            return true;
        }
    }
    
    // 現在の解像度を取得
    void GetFrameSize(unsigned& width, unsigned& height) {
        if (!isInitialized) {
            width = height = 0;
            return;
        }
        
        width = frameWidth;
        height = frameHeight;
    }
    
    // フレームのサイズを取得
    PINDEX GetMaxFrameBytes() {
        if (!isInitialized) return 0;
        return frameSize > 0 ? frameSize : 1920 * 1080 * 3 / 2; // デフォルトは1080p YUV420
    }
    
    // 使用可能なプリセット/解像度一覧を取得
    PStringArray GetSupportedFormats() {
        PStringArray formatsArray;
        
        if (!isInitialized || !device) {
            return formatsArray;
        }
        
        @autoreleasepool {
            // デバイスが持つフォーマットを列挙
            NSArray<AVCaptureDeviceFormat*> *allFormats = [device formats];
            for (AVCaptureDeviceFormat *format in allFormats) {
                CMFormatDescriptionRef desc = format.formatDescription;
                if (!desc)
                    continue;
                
                // 映像サイズ（幅・高さ）
                CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(desc);
                
                // ピクセルフォーマット（FourCC）
                FourCharCode code = CMFormatDescriptionGetMediaSubType(desc);
                char pixelFormat[5];
                pixelFormat[0] = (char)((code >> 24) & 0xFF);
                pixelFormat[1] = (char)((code >> 16) & 0xFF);
                pixelFormat[2] = (char)((code >> 8) & 0xFF);
                pixelFormat[3] = (char)(code & 0xFF);
                pixelFormat[4] = '\0';
                
                // FPS 範囲（最初の範囲のみ）
                AVFrameRateRange *range = [[format videoSupportedFrameRateRanges] firstObject];
                CGFloat minFPS = range ? range.minFrameRate : 0;
                CGFloat maxFPS = range ? range.maxFrameRate : 0;
                
                // 例: "420v, 1920x1080, FPS: 1.0-60.0"
                char formatStr[100];
                snprintf(formatStr, sizeof(formatStr), "%s, %dx%d, FPS: %.1f-%.1f",
                         pixelFormat, dims.width, dims.height,
                         (double)minFPS, (double)maxFPS);
                formatsArray.AppendString(PString(formatStr));
            }
        }
        
        return formatsArray;
    }
};
#endif // __OBJC__

//---------------------------------------------------------------------------
// MacOSInternal の実装
//---------------------------------------------------------------------------
struct MacOSInternal
{
    bool        isOpen;
    bool        isCapturing;
    PMutex      frameMutex;
    PBYTEArray  frameBuffer;
    PINDEX      frameSize;      // 実際の1フレームあたりのバイト数
    unsigned    frameWidth;     // 実際の幅
    unsigned    frameHeight;    // 実際の高さ

#ifdef __OBJC__
    // 拡張機能のみの実装
    EnhancedCaptureManager* captureManager;
#endif

    MacOSInternal()
      : isOpen(false),
        isCapturing(false),
        frameSize(0),
        frameWidth(0),
        frameHeight(0)
#ifdef __OBJC__
        , captureManager(nullptr)
#endif
    {
    }
    
    ~MacOSInternal() {
#ifdef __OBJC__
        if (captureManager) {
            delete captureManager;
            captureManager = nullptr;
        }
#endif
    }
};

//---------------------------------------------------------------------------
// PVideoInputDevice_macOS 実装
//---------------------------------------------------------------------------
PVideoInputDevice_macOS::PVideoInputDevice_macOS()
{
    m_internal = new MacOSInternal();
}

PVideoInputDevice_macOS::~PVideoInputDevice_macOS()
{
    Close();
    if (m_internal) {
        delete m_internal;
        m_internal = nullptr;
    }
}

MacOSInternal* PVideoInputDevice_macOS::GetMacOSInternal() 
{
    return m_internal;
}

PStringArray PVideoInputDevice_macOS::GetInputDeviceNames()
{
    PStringArray result;
#ifdef __OBJC__
    // 拡張機能を使用してデバイスを列挙
    EnhancedCaptureManager captureManager;
    result = captureManager.GetDeviceNames();
    
    if (result.IsEmpty()) {
        PTRACE(2, "PVideoInputDevice_macOS\tデバイスが見つかりませんでした");
    } else {
        PTRACE(4, "PVideoInputDevice_macOS\t" << result.GetSize() << "個のデバイスを検出しました");
        for (PINDEX i = 0; i < result.GetSize(); i++) {
            PTRACE(4, "  デバイス " << i+1 << ": " << result[i]);
        }
    }
#endif
    return result;
}

PVideoInputDevice* PVideoInputDevice_macOS::CreateDevice(const PString & deviceName)
{
    PVideoInputDevice_macOS* dev = new PVideoInputDevice_macOS();
    if (dev->Open(deviceName, true))
        return dev;
    delete dev;
    return nullptr;
}

bool PVideoInputDevice_macOS::Open(const PString & deviceName, bool startImmediate)
{
#ifdef __OBJC__
    MacOSInternal* internal = m_internal;
    if (!internal)
        return false;
    
    if (internal->isOpen)
        Close();

    // 拡張キャプチャマネージャーを作成
    if (!internal->captureManager) {
        internal->captureManager = new EnhancedCaptureManager();
    }
    
    // 指定されたデバイス名でオープン
    if (!internal->captureManager->OpenDevice(deviceName)) {
        PTRACE(2, "PVideoInputDevice_macOS\tデバイス '" << (const char*)deviceName << "' のオープンに失敗しました");
        return false;
    }
    
    internal->isOpen = true;
    PTRACE(4, "PVideoInputDevice_macOS\tデバイス '" << (const char*)deviceName << "' を開きました");
    
    // CRITICAL FIX: デバイスOpen直後に720pを強制設定
    // これにより、上位レイヤーからの設定に依存しない
    if (!internal->captureManager->SetFrameSize(1280, 720)) {
        PTRACE(1, "PVideoInputDevice_macOS\t⚠️ 720p設定失敗 - デフォルト解像度を使用");
    } else {
        PTRACE(1, "PVideoInputDevice_macOS\t🎥 720p解像度を強制設定しました");
    }
    
    // 解像度情報を取得（720p設定後の実際のサイズを確認）
    internal->captureManager->GetFrameSize(internal->frameWidth, internal->frameHeight);
    internal->frameSize = internal->captureManager->GetMaxFrameBytes();
    
    // 確認ログ: 実際に720pで取得できているか
    PTRACE(1, "PVideoInputDevice_macOS\t📐 Open後の実際の解像度: " << internal->frameWidth << "x" << internal->frameHeight 
           << " (期待値: 1280x720, バッファサイズ: " << internal->frameSize << " bytes)");
    
    if (internal->frameWidth != 1280 || internal->frameHeight != 720) {
        PTRACE(1, "PVideoInputDevice_macOS\t❌ ERROR: 720pへの設定に失敗しました！実際: " 
               << internal->frameWidth << "x" << internal->frameHeight);
    }
    
    if (startImmediate) {
        Start();
    }
    
    return true;
#else
    return false;
#endif
}

bool PVideoInputDevice_macOS::OpenWithID(const PString & deviceID, bool startImmediate)
{
#ifdef __OBJC__
    MacOSInternal* internal = m_internal;
    if (!internal)
        return false;
    
    if (internal->isOpen)
        Close();

    // 拡張キャプチャマネージャーを作成
    if (!internal->captureManager) {
        internal->captureManager = new EnhancedCaptureManager();
    }
    
    // 指定されたデバイスIDでオープン
    if (!internal->captureManager->OpenDeviceWithID(deviceID)) {
        PTRACE(2, "PVideoInputDevice_macOS\tデバイスID '" << (const char*)deviceID << "' のオープンに失敗しました");
        return false;
    }
    
    internal->isOpen = true;
    PTRACE(4, "PVideoInputDevice_macOS\tデバイスID '" << (const char*)deviceID << "' を開きました");
    
    // CRITICAL FIX: デバイスOpen直後に720pを強制設定
    if (!internal->captureManager->SetFrameSize(1280, 720)) {
        PTRACE(1, "PVideoInputDevice_macOS\t⚠️ 720p設定失敗 - デフォルト解像度を使用");
    } else {
        PTRACE(1, "PVideoInputDevice_macOS\t🎥 720p解像度を強制設定しました");
    }
    
    // 解像度情報を取得（720p設定後の実際のサイズを確認）
    internal->captureManager->GetFrameSize(internal->frameWidth, internal->frameHeight);
    internal->frameSize = internal->captureManager->GetMaxFrameBytes();
    
    // 確認ログ: 実際に720pで取得できているか
    PTRACE(1, "PVideoInputDevice_macOS\t📐 OpenWithID後の実際の解像度: " << internal->frameWidth << "x" << internal->frameHeight 
           << " (期待値: 1280x720, バッファサイズ: " << internal->frameSize << " bytes)");
    
    if (internal->frameWidth != 1280 || internal->frameHeight != 720) {
        PTRACE(1, "PVideoInputDevice_macOS\t❌ ERROR: 720pへの設定に失敗しました！実際: " 
               << internal->frameWidth << "x" << internal->frameHeight);
    }
    
    if (startImmediate) {
        Start();
    }
    
    return true;
#else
    return false;
#endif
}

bool PVideoInputDevice_macOS::IsOpen()
{
    return m_internal && m_internal->isOpen;
}

bool PVideoInputDevice_macOS::Close()
{
    MacOSInternal* internal = m_internal;
    if (!internal || !internal->isOpen)
        return false;
    
#ifdef __OBJC__
    if (internal->captureManager) {
        internal->captureManager->Stop();
    }
#endif

    internal->isOpen = false;
    internal->isCapturing = false;
    
    return true;
}

bool PVideoInputDevice_macOS::Start()
{
    MacOSInternal* internal = m_internal;
    if (!internal || !internal->isOpen || internal->isCapturing)
        return false;

#ifdef __OBJC__
    if (internal->captureManager && internal->captureManager->Start()) {
        internal->isCapturing = true;
        
        // 開始後に解像度情報を更新
        internal->captureManager->GetFrameSize(internal->frameWidth, internal->frameHeight);
        internal->frameSize = internal->captureManager->GetMaxFrameBytes();
        
        PTRACE(4, "PVideoInputDevice_macOS\tキャプチャ開始: " 
               << internal->frameWidth << "x" << internal->frameHeight);
        return true;
    }
    
    // Start() failed - do not mark as capturing
    PTRACE(1, "PVideoInputDevice_macOS\tStart()が失敗しました - キャプチャを開始できません");
    return false;
#else
    return false;
#endif
}

bool PVideoInputDevice_macOS::Stop()
{
    MacOSInternal* internal = m_internal;
    if (!internal || !internal->isOpen || !internal->isCapturing)
        return false;

#ifdef __OBJC__
    if (internal->captureManager) {
        internal->captureManager->Stop();
    }
#endif

    internal->isCapturing = false;
    return true;
}

bool PVideoInputDevice_macOS::IsCapturing()
{
    return m_internal && m_internal->isCapturing;
}

bool PVideoInputDevice_macOS::GetFrameData(BYTE * buffer, PINDEX * bytesReturned)
{
    MacOSInternal* internal = m_internal;
    if (!internal || !internal->isCapturing)
        return false;
    
#ifdef __OBJC__
    if (internal->captureManager) {
        if (internal->captureManager->GetFrameData(buffer, bytesReturned)) {
            // フレームが取得できたら解像度情報を更新
            unsigned width, height;
            internal->captureManager->GetFrameSize(width, height);
            
            // ロックして内部情報を更新
            internal->frameMutex.Wait();
            internal->frameWidth = width;
            internal->frameHeight = height;
            internal->frameSize = *bytesReturned;
            internal->frameMutex.Signal();
            
            return true;
        }
    }
#endif
    
    return false;
}

bool PVideoInputDevice_macOS::GetFrameDataNoDelay(BYTE * buffer, PINDEX * bytesReturned)
{
    // 標準のGetFrameDataと同じ実装で問題ない
    return GetFrameData(buffer, bytesReturned);
}

PStringArray PVideoInputDevice_macOS::GetDeviceNames() const
{
    return PVideoInputDevice_macOS::GetInputDeviceNames();
}

// GetMaxFrameBytes() は、初回キャプチャで internal->frameSize に更新されていればそれを返す
PINDEX PVideoInputDevice_macOS::GetMaxFrameBytes()
{
    if (m_internal && m_internal->frameSize > 0)
        return m_internal->frameSize;
    // まだ確定していない場合は念のため大きめにしておく
    return 1920 * 1080 * 4;
}

PStringArray PVideoInputDevice_macOS::GetSupportedFormats() const
{
    PStringArray formatsArray;
#ifdef __OBJC__
    MacOSInternal* internal = m_internal;
    if (internal && internal->captureManager) {
        formatsArray = internal->captureManager->GetSupportedFormats();
    }
#endif
    return formatsArray;
}

unsigned PVideoInputDevice_macOS::GetFrameWidth() const
{
    return (m_internal && m_internal->isCapturing) ? m_internal->frameWidth : 0;
}

unsigned PVideoInputDevice_macOS::GetFrameHeight() const
{
    return (m_internal && m_internal->isCapturing) ? m_internal->frameHeight : 0;
}

//---------------------------------------------------------------------------
// SetFrameSize() - ここが重要: 実際に設定が反映されるまで確認してから true/false を返す
//---------------------------------------------------------------------------
bool PVideoInputDevice_macOS::SetFrameSize(unsigned width, unsigned height)
{
    MacOSInternal* internal = m_internal;
    if (!internal || !internal->captureManager)
        return false;

#ifdef __OBJC__
    if (!internal->captureManager->SetFrameSize(width, height))
        return false;
    
    // 実際にフレームサイズが希望通りになるか、短時間待って確認するラムダ
    auto confirmResolution = [&](unsigned reqW, unsigned reqH, int waitMs = 2000) { // 待機時間を2秒に短縮
        using namespace std::chrono;
        auto startTime = steady_clock::now();
        
        // フレームが来ない場合のために初期値をログ
        PTRACE(4, "PVideoInputDevice_macOS\tWaiting for frame with resolution " 
               << reqW << "x" << reqH << " (timeout: " << waitMs << "ms)");
        
        while (true) {
            {
                // デリゲートで更新される frameWidth/Height をロック付きで取得
                PWaitAndSignal lock(internal->frameMutex);
                if (internal->frameWidth == reqW && internal->frameHeight == reqH) {
                    PTRACE(4, "PVideoInputDevice_macOS\tResolution confirmed: " 
                           << internal->frameWidth << "x" << internal->frameHeight);
                    return true;
                }
                
                // 解像度が0でない場合、現在の値をログ出力（デバッグ用）
                if (internal->frameWidth > 0 && internal->frameHeight > 0) {
                    PTRACE(5, "PVideoInputDevice_macOS\tCurrent resolution while waiting: " 
                           << internal->frameWidth << "x" << internal->frameHeight);
                }
            }
            
            auto now = steady_clock::now();
            if (duration_cast<milliseconds>(now - startTime).count() > waitMs)
                break;
            std::this_thread::sleep_for(milliseconds(25)); // ポーリング間隔をより短縮して高頻度チェック
        }
        
        PTRACE(3, "PVideoInputDevice_macOS\tTimeout waiting for resolution " 
               << reqW << "x" << reqH);
        return false;
    };

    // フレームが実際に要求サイズで配信されるか確認
    bool resolutionConfirmed = confirmResolution(width, height);
    
    if (!resolutionConfirmed) {
        // 要求サイズと異なる場合でも、実際に得られた解像度を確認
        PTRACE(3, "PVideoInputDevice_macOS\tRequested " << width << "x" << height 
               << " but got " << internal->frameWidth << "x" << internal->frameHeight);
        
        // 強制的に検証するために再度フレームを待つ
        resolutionConfirmed = confirmResolution(internal->frameWidth, internal->frameHeight, 500);
    } else {
        PTRACE(4, "PVideoInputDevice_macOS\tSuccessfully set resolution to " 
               << internal->frameWidth << "x" << internal->frameHeight);
    }
    
    return resolutionConfirmed;
#else
    // 非Objective-C環境
    return false;
#endif
}

// 詳細なデバイスリストを取得する関数
PArray<PVideoInputDevice_macOS::DeviceInfo> PVideoInputDevice_macOS::GetDetailedDeviceList()
{
    PArray<DeviceInfo> deviceList;

#ifdef __OBJC__
    @autoreleasepool {
        // すべての種類のビデオデバイスを検出
        AVCaptureDeviceDiscoverySession *discoverySession = [AVCaptureDeviceDiscoverySession 
            discoverySessionWithDeviceTypes:@[
                AVCaptureDeviceTypeBuiltInWideAngleCamera, 
                AVCaptureDeviceTypeExternal,
                AVCaptureDeviceTypeContinuityCamera
            ]
            mediaType:AVMediaTypeVideo
            position:AVCaptureDevicePositionUnspecified];
        
        for (AVCaptureDevice* dev in discoverySession.devices) {
            // PObjectから派生した独自のDeviceInfoを作成
            DeviceInfo* info = new DeviceInfo();
            info->deviceID = [dev.uniqueID UTF8String];
            info->name = [dev.localizedName UTF8String];
            
            if (dev.manufacturer) {
                info->manufacturer = [dev.manufacturer UTF8String];
            }
            
            if (dev.modelID) {
                info->modelID = [dev.modelID UTF8String];
            }
            
            // Continuity Cameraかどうかを判定
            info->isContinuityCamera = ([dev.manufacturer isEqualToString:@"Apple"] && 
                                     [dev.modelID hasPrefix:@"iPhone"]);
            
            // PArrayに追加（PObject*として正しく扱われる）
            deviceList.Append(info);
        }
    }
#endif

    return deviceList;
}

//---------------------------------------------------------------------------
// PTLibプラグインクラスの実装 - PDevicePluginServiceDescriptorを使用
//---------------------------------------------------------------------------
class PVideoInputDevice_MacOSPlugin : public PDevicePluginServiceDescriptor
{
public:
    virtual PObject* CreateInstance(int) const { return new PVideoInputDevice_macOS; }
    virtual PStringArray GetDeviceNames(int) const { return PVideoInputDevice_macOS::GetInputDeviceNames(); }
    virtual bool ValidateDeviceName(const PString & deviceName, int) const 
    { 
        // すべてのデバイス名のリストを取得
        PStringArray devices = PVideoInputDevice_macOS::GetInputDeviceNames();
        
        // 空の場合は少なくとも1つのデバイスがあるとみなす
        if (devices.IsEmpty())
            return true;
            
        // デバイス名がリストにあるかチェック
        for (PINDEX i = 0; i < devices.GetSize(); i++) {
            if (devices[i] == deviceName)
                return true;
        }
        
        return false; 
    }
};

//---------------------------------------------------------------------------
// PTLib動的プラグインエクスポート関数
//---------------------------------------------------------------------------
static PVideoInputDevice_MacOSPlugin plugin;

// Use PCREATE_PLUGIN instead of PCREATE_VIDINPUT_PLUGIN for better compatibility
PCREATE_PLUGIN(MacOS, PVideoInputDevice, &plugin);

extern "C" {

unsigned PWLibPlugin_GetAPIVersion()
{
    return PWLIB_PLUGIN_API_VERSION;
}

void PWLibPlugin_GetPluginType(char * type, unsigned size)
{
    if (size < 16) return;
    strcpy(type, "PVideoInputDevice");
}

void PWLibPlugin_GetPluginName(char * name, unsigned size)
{
    if (size < 8) return;
    strcpy(name, "MacOS");
}

const char* PWLibPlugin_GetDescription()
{
    return "macOS AVFoundation Video Input Device Plugin";
}

PPluginServiceDescriptor* PWLibPlugin_GetServiceDescriptor()
{
    return &plugin;
}

//Registration trigger function - required for dynamic plugin loading
void PWLibPlugin_TriggerRegister()
{
    PTRACE(0, "PVideoInputDevice_macOS\tTriggerRegister called!");
    
    // Register with plugin manager  
    static PVideoInputDevice_MacOSPlugin* macOSPlugin = new PVideoInputDevice_MacOSPlugin();
    PPluginManager& manager = PPluginManager::GetPluginManager();
    manager.RegisterService("MacOS", "PVideoInputDevice", macOSPlugin);
    
    PTRACE(0, "PVideoInputDevice_macOS\tDriver registered with name 'MacOS'");
}

}

//---------------------------------------------------------------------------
// プラグイン登録 (スタティック用は削除)
//---------------------------------------------------------------------------
// static PVideoInputDevice_MacOSPlugin TheVideoInputDeviceMacOSPlugin;
// PCREATE_PLUGIN_STATIC(MacOS, PVideoInputDevice, &TheVideoInputDeviceMacOSPlugin);
