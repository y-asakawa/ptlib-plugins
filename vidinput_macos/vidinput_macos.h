/*
 * vidinput_macos.h
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
 */

#ifndef PTLIB_VIDINPUT_MACOS_H
#define PTLIB_VIDINPUT_MACOS_H

#include <ptlib/videoio.h>
#include <ptlib/pluginmgr.h>

// PTLibプラグインAPI定義
#ifndef PWLIB_PLUGIN_API_VERSION
#define PWLIB_PLUGIN_API_VERSION 1
#endif

// 前方宣言
struct MacOSInternal;

/**
 * macOS用ビデオ入力デバイス (ラッパークラス)。
 */
class PVideoInputDevice_macOS : public PVideoInputDevice
{
  PCLASSINFO(PVideoInputDevice_macOS, PVideoInputDevice);

public:
    PVideoInputDevice_macOS();
    ~PVideoInputDevice_macOS();

    // 利用可能なデバイス名一覧を取得
    static PStringArray GetInputDeviceNames();

    // 指定デバイス名で生成
    static PVideoInputDevice* CreateDevice(const PString & deviceName);

    // 仮想関数のオーバーライド
    bool Open(const PString & deviceName, bool startImmediate = true) override;
    bool IsOpen() override;
    bool Close() override;
    bool Start() override;
    bool Stop() override;
    bool IsCapturing() override;
    bool GetFrameData(BYTE * buffer, PINDEX * bytesReturned) override;
    bool GetFrameDataNoDelay(BYTE * buffer, PINDEX * bytesReturned) override;
    PStringArray GetDeviceNames() const override;

    // ここを修正：実際のフレームサイズに基づいて返すように変更
    virtual PINDEX GetMaxFrameBytes() override;

    // 追加：実際の解像度を取得するメソッド - override キーワードを追加
    virtual unsigned GetFrameWidth() const override;
    virtual unsigned GetFrameHeight() const override;

    // フレームサイズを設定するメソッドを追加
    virtual bool SetFrameSize(unsigned width, unsigned height) override;

    // 対応する色フォーマット情報を文字列リストで取得するメソッド
    PStringArray GetSupportedFormats() const;

    // デバイスの詳細情報を含む構造体
    struct DeviceInfo : public PObject {
        PCLASSINFO(DeviceInfo, PObject);
        
        PString deviceID;    // デバイスの一意のID
        PString name;        // 表示名
        PString manufacturer; // 製造元
        PString modelID;     // モデルID
        bool isContinuityCamera; // Continuityカメラかどうかのフラグ
        
        DeviceInfo() : isContinuityCamera(false) {}
    };

    // デバイス情報一覧を取得する新しいメソッド
    static PArray<DeviceInfo> GetDetailedDeviceList();

    // デバイスIDを指定して初期化する新しいOpen関数
    bool OpenWithID(const PString & deviceID, bool startImmediate = true);

public:
    struct MacOSInternal* GetMacOSInternal();

private:
    MacOSInternal* m_internal;
};

#endif // PTLIB_VIDINPUT_MACOS_H
