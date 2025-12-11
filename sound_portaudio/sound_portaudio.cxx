/*
 * sound_portaudio.cxx
 *
 * PortAudio Sound Driver Plugin for PTLib
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

#pragma implementation "sound_portaudio.h"

#include <ptlib.h>
#include "sound_portaudio.h"

// Register this sound channel plugin
PCREATE_SOUND_PLUGIN(PortAudio, PSoundChannelPortAudio);

// Static members
bool PSoundChannelPortAudio::sInitialized = false;
PMutex PSoundChannelPortAudio::sInitMutex;

void PSoundChannelPortAudio::Initialize()
{
    PWaitAndSignal lock(sInitMutex);
    if (!sInitialized) {
        PaError err = Pa_Initialize();
        if (err != paNoError) {
            PTRACE(1, "PortAudio\tFailed to initialize: " << Pa_GetErrorText(err));
        } else {
            sInitialized = true;
            PTRACE(3, "PortAudio\tInitialized successfully, version: " << Pa_GetVersionText());
        }
    }
}

void PSoundChannelPortAudio::Terminate()
{
    PWaitAndSignal lock(sInitMutex);
    if (sInitialized) {
        Pa_Terminate();
        sInitialized = false;
        PTRACE(3, "PortAudio\tTerminated");
    }
}

///////////////////////////////////////////////////////////////////////////////

PSoundChannelPortAudio::PSoundChannelPortAudio()
{
    PTRACE(6, "PortAudio\tConstructor (no args)");
    Construct();
}

PSoundChannelPortAudio::PSoundChannelPortAudio(const PString & device,
                                               Directions dir,
                                               unsigned numChannels,
                                               unsigned sampleRate,
                                               unsigned bitsPerSample)
{
    PTRACE(6, "PortAudio\tConstructor with args: device=" << device 
           << " dir=" << (dir == Player ? "Player" : "Recorder")
           << " ch=" << numChannels << " rate=" << sampleRate << " bits=" << bitsPerSample);
    Construct();
    Open(device, dir, numChannels, sampleRate, bitsPerSample);
}

void PSoundChannelPortAudio::Construct()
{
    Initialize();
    
    os_handle = -1;
    mStream = NULL;
    mDeviceIndex = paNoDevice;
    mNumChannels = 1;
    mSampleRate = 8000;
    mBitsPerSample = 16;
    mDirection = Player;
    mBufferSize = 320;  // 20ms at 8kHz, 16-bit mono
    mBufferCount = 2;
    mReadPos = 0;
    mWritePos = 0;
    mBufferedBytes = 0;
}

PSoundChannelPortAudio::~PSoundChannelPortAudio()
{
    PTRACE(6, "PortAudio\tDestructor");
    Close();
}

///////////////////////////////////////////////////////////////////////////////
// Device enumeration

PStringArray PSoundChannelPortAudio::GetDeviceNames(Directions dir)
{
    PTRACE(6, "PortAudio\tGetDeviceNames for " << (dir == Player ? "Player" : "Recorder"));
    
    // Ensure PortAudio is initialized
    {
        PWaitAndSignal lock(sInitMutex);
        if (!sInitialized) {
            PaError err = Pa_Initialize();
            if (err != paNoError) {
                PTRACE(1, "PortAudio\tFailed to initialize for device enumeration");
                PStringArray empty;
                return empty;
            }
            sInitialized = true;
        }
    }
    
    PStringArray devices;
    
    // Add default device first
    devices.AppendString("PortAudio");
    
    int numDevices = Pa_GetDeviceCount();
    if (numDevices < 0) {
        PTRACE(1, "PortAudio\tError getting device count: " << Pa_GetErrorText(numDevices));
        return devices;
    }
    
    for (int i = 0; i < numDevices; i++) {
        const PaDeviceInfo *info = Pa_GetDeviceInfo(i);
        if (info == NULL) continue;
        
        bool isInput = info->maxInputChannels > 0;
        bool isOutput = info->maxOutputChannels > 0;
        
        if ((dir == Recorder && isInput) || (dir == Player && isOutput)) {
            devices.AppendString(PString(info->name));
            PTRACE(6, "PortAudio\t  Device " << i << ": " << info->name 
                   << " (in=" << info->maxInputChannels 
                   << " out=" << info->maxOutputChannels
                   << " rate=" << info->defaultSampleRate << ")");
        }
    }
    
    return devices;
}

PString PSoundChannelPortAudio::GetDefaultDevice(Directions dir)
{
    return "PortAudio";
}

PaDeviceIndex PSoundChannelPortAudio::GetDeviceIndex(const PString & device, Directions dir)
{
    // PTLib passes device names as "DriverName DeviceName"
    // We need to strip the "PortAudio " prefix if present
    PString actualDevice = device;
    if (device.Find("PortAudio ") == 0) {
        actualDevice = device.Mid(10);  // Skip "PortAudio "
    }
    
    PTRACE(4, "PortAudio\tGetDeviceIndex: input='" << device 
           << "' actual='" << actualDevice << "' dir=" << (dir == Recorder ? "Recorder" : "Player"));
    
    if (actualDevice.IsEmpty() || actualDevice == "PortAudio") {
        // Use default device
        PaDeviceIndex defaultDev = (dir == Recorder) ? Pa_GetDefaultInputDevice() : Pa_GetDefaultOutputDevice();
        PTRACE(4, "PortAudio\tUsing default device index: " << defaultDev);
        return defaultDev;
    }
    
    int numDevices = Pa_GetDeviceCount();
    for (int i = 0; i < numDevices; i++) {
        const PaDeviceInfo *info = Pa_GetDeviceInfo(i);
        if (info != NULL) {
            PTRACE(5, "PortAudio\tChecking device " << i << ": '" << info->name 
                   << "' (in=" << info->maxInputChannels << " out=" << info->maxOutputChannels << ")");
            if (actualDevice == info->name) {
                // Check if device supports the required direction
                bool supportsDirection = (dir == Recorder) ? (info->maxInputChannels > 0) : (info->maxOutputChannels > 0);
                if (supportsDirection) {
                    PTRACE(4, "PortAudio\tFound matching device at index " << i << " (supports " << (dir == Recorder ? "input" : "output") << ")");
                    return i;
                } else {
                    PTRACE(5, "PortAudio\tDevice " << i << " found but does not support " << (dir == Recorder ? "input" : "output") << ", continuing search");
                }
            }
        }
    }
    
    // Fallback to default
    PTRACE(3, "PortAudio\tDevice '" << actualDevice << "' not found, using default");
    if (dir == Recorder)
        return Pa_GetDefaultInputDevice();
    else
        return Pa_GetDefaultOutputDevice();
}

///////////////////////////////////////////////////////////////////////////////
// Open/Close

PBoolean PSoundChannelPortAudio::Open(const PString & device,
                                      Directions dir,
                                      unsigned numChannels,
                                      unsigned sampleRate,
                                      unsigned bitsPerSample)
{
    PWaitAndSignal lock(mMutex);
    
    PTRACE(3, "PortAudio\tOpen: device=" << device 
           << " dir=" << (dir == Player ? "Player" : "Recorder")
           << " ch=" << numChannels << " rate=" << sampleRate << " bits=" << bitsPerSample);
    
    Close();
    
    if (!sInitialized) {
        Initialize();
        if (!sInitialized) {
            PTRACE(1, "PortAudio\tFailed to initialize");
            return PFalse;
        }
    }
    
    mDevice = device;
    mDirection = dir;
    mNumChannels = numChannels;
    mSampleRate = sampleRate;
    mBitsPerSample = bitsPerSample;
    
    // Validate parameters
    if (bitsPerSample != 16) {
        PTRACE(1, "PortAudio\tOnly 16-bit samples supported");
        return PFalse;
    }
    
    mDeviceIndex = GetDeviceIndex(device, dir);
    if (mDeviceIndex == paNoDevice) {
        PTRACE(1, "PortAudio\tNo suitable device found");
        return PFalse;
    }
    
    const PaDeviceInfo *deviceInfo = Pa_GetDeviceInfo(mDeviceIndex);
    if (deviceInfo == NULL) {
        PTRACE(1, "PortAudio\tCannot get device info");
        return PFalse;
    }
    
    PTRACE(3, "PortAudio\tUsing device: " << deviceInfo->name 
           << " (index=" << mDeviceIndex << ")");
    
    // Validate and adjust channel count based on device capabilities
    int maxChannels = (dir == Player) 
        ? deviceInfo->maxOutputChannels 
        : deviceInfo->maxInputChannels;
    
    if (maxChannels <= 0) {
        PTRACE(1, "PortAudio\tDevice does not support " 
               << (dir == Player ? "output" : "input"));
        return PFalse;
    }
    
    // Use device's channel count if requested channels exceed device capability
    unsigned actualChannels = numChannels;
    if ((int)numChannels > maxChannels) {
        PTRACE(2, "PortAudio\tRequested " << numChannels << " channels, "
               << "device supports max " << maxChannels << ", adjusting");
        actualChannels = maxChannels;
    }
    mNumChannels = actualChannels;
    
    // Check if sample rate is supported, fallback to device default if not
    unsigned actualSampleRate = sampleRate;
    double deviceDefaultRate = deviceInfo->defaultSampleRate;
    
    // For USB audio devices, sometimes the requested rate isn't supported
    // Try the requested rate first, but we'll fallback if Pa_OpenStream fails
    PTRACE(4, "PortAudio\tDevice default sample rate: " << deviceDefaultRate);
    
    // Setup stream parameters
    PaStreamParameters params;
    memset(&params, 0, sizeof(params));
    params.device = mDeviceIndex;
    params.channelCount = actualChannels;
    params.sampleFormat = paInt16;
    params.suggestedLatency = (dir == Player) 
        ? deviceInfo->defaultLowOutputLatency 
        : deviceInfo->defaultLowInputLatency;
    params.hostApiSpecificStreamInfo = NULL;
    
    // Calculate frames per buffer (20ms worth of samples)
    unsigned long framesPerBuffer = actualSampleRate / 50;  // 20ms
    
    PaError err;
    if (dir == Player) {
        err = Pa_OpenStream(&mStream,
                           NULL,        // No input
                           &params,     // Output params
                           actualSampleRate,
                           framesPerBuffer,
                           paClipOff,
                           NULL,        // No callback (blocking I/O)
                           NULL);
    } else {
        err = Pa_OpenStream(&mStream,
                           &params,     // Input params
                           NULL,        // No output
                           actualSampleRate,
                           framesPerBuffer,
                           paClipOff,
                           NULL,        // No callback (blocking I/O)
                           NULL);
    }
    
    // If failed with requested sample rate, try device's default rate
    if (err != paNoError && actualSampleRate != (unsigned)deviceDefaultRate) {
        PTRACE(2, "PortAudio\tFailed with " << actualSampleRate << "Hz, "
               << "trying device default " << deviceDefaultRate << "Hz");
        actualSampleRate = (unsigned)deviceDefaultRate;
        framesPerBuffer = actualSampleRate / 50;
        mSampleRate = actualSampleRate;
        
        if (dir == Player) {
            err = Pa_OpenStream(&mStream,
                               NULL,
                               &params,
                               actualSampleRate,
                               framesPerBuffer,
                               paClipOff,
                               NULL,
                               NULL);
        } else {
            err = Pa_OpenStream(&mStream,
                               &params,
                               NULL,
                               actualSampleRate,
                               framesPerBuffer,
                               paClipOff,
                               NULL,
                               NULL);
        }
    }
    
    if (err != paNoError) {
        PTRACE(1, "PortAudio\tFailed to open stream: " << Pa_GetErrorText(err));
        mStream = NULL;
        return PFalse;
    }
    
    // Start the stream
    err = Pa_StartStream(mStream);
    if (err != paNoError) {
        PTRACE(1, "PortAudio\tFailed to start stream: " << Pa_GetErrorText(err));
        Pa_CloseStream(mStream);
        mStream = NULL;
        return PFalse;
    }
    
    os_handle = 1;
    
    PTRACE(3, "PortAudio\t✅ Stream opened successfully: " 
           << deviceInfo->name << " @ " << sampleRate << "Hz");
    
    return PTrue;
}

PBoolean PSoundChannelPortAudio::Setup()
{
    return PTrue;
}

PBoolean PSoundChannelPortAudio::Close()
{
    PWaitAndSignal lock(mMutex);
    
    PTRACE(6, "PortAudio\tClose");
    
    if (mStream != NULL) {
        Pa_StopStream(mStream);
        Pa_CloseStream(mStream);
        mStream = NULL;
    }
    
    os_handle = -1;
    return PTrue;
}

PBoolean PSoundChannelPortAudio::IsOpen() const
{
    return os_handle >= 0 && mStream != NULL;
}

///////////////////////////////////////////////////////////////////////////////
// Read/Write

PBoolean PSoundChannelPortAudio::Write(const void * buf, PINDEX len)
{
    PWaitAndSignal lock(mMutex);
    
    if (!IsOpen()) {
        PTRACE(4, "PortAudio\tWrite failed - not open");
        return PFalse;
    }
    
    if (mDirection != Player) {
        PTRACE(4, "PortAudio\tWrite failed - not a player");
        return PFalse;
    }
    
    // Calculate number of frames
    unsigned bytesPerFrame = mNumChannels * (mBitsPerSample / 8);
    unsigned long frames = len / bytesPerFrame;
    
    PaError err = Pa_WriteStream(mStream, buf, frames);
    if (err != paNoError && err != paOutputUnderflowed) {
        PTRACE(4, "PortAudio\tWrite failed: " << Pa_GetErrorText(err));
        return PFalse;
    }
    
    lastWriteCount = len;
    return PTrue;
}

PBoolean PSoundChannelPortAudio::Read(void * buf, PINDEX len)
{
    PWaitAndSignal lock(mMutex);
    
    if (!IsOpen()) {
        PTRACE(4, "PortAudio\tRead failed - not open");
        return PFalse;
    }
    
    if (mDirection != Recorder) {
        PTRACE(4, "PortAudio\tRead failed - not a recorder");
        return PFalse;
    }
    
    // Calculate number of frames
    unsigned bytesPerFrame = mNumChannels * (mBitsPerSample / 8);
    unsigned long frames = len / bytesPerFrame;
    
    PaError err = Pa_ReadStream(mStream, buf, frames);
    if (err != paNoError && err != paInputOverflowed) {
        PTRACE(4, "PortAudio\tRead failed: " << Pa_GetErrorText(err));
        return PFalse;
    }
    
    lastReadCount = len;
    return PTrue;
}

///////////////////////////////////////////////////////////////////////////////
// Format

PBoolean PSoundChannelPortAudio::SetFormat(unsigned numChannels,
                                           unsigned sampleRate,
                                           unsigned bitsPerSample)
{
    PTRACE(6, "PortAudio\tSetFormat: ch=" << numChannels 
           << " rate=" << sampleRate << " bits=" << bitsPerSample);
    
    if (bitsPerSample != 16) {
        PTRACE(1, "PortAudio\tOnly 16-bit samples supported");
        return PFalse;
    }
    
    // If stream is already open, need to reopen with new format
    if (IsOpen()) {
        PString device = mDevice;
        Directions dir = mDirection;
        Close();
        return Open(device, dir, numChannels, sampleRate, bitsPerSample);
    }
    
    mNumChannels = numChannels;
    mSampleRate = sampleRate;
    mBitsPerSample = bitsPerSample;
    
    return PTrue;
}

unsigned PSoundChannelPortAudio::GetChannels() const
{
    return mNumChannels;
}

unsigned PSoundChannelPortAudio::GetSampleRate() const
{
    return mSampleRate;
}

unsigned PSoundChannelPortAudio::GetSampleSize() const
{
    return mBitsPerSample;
}

///////////////////////////////////////////////////////////////////////////////
// Buffers

PBoolean PSoundChannelPortAudio::SetBuffers(PINDEX size, PINDEX count)
{
    PTRACE(6, "PortAudio\tSetBuffers: size=" << size << " count=" << count);
    mBufferSize = size;
    mBufferCount = count;
    return PTrue;
}

PBoolean PSoundChannelPortAudio::GetBuffers(PINDEX & size, PINDEX & count)
{
    size = mBufferSize;
    count = mBufferCount;
    return PTrue;
}

///////////////////////////////////////////////////////////////////////////////
// Not implemented (optional features)

PBoolean PSoundChannelPortAudio::PlaySound(const PSound & sound, PBoolean wait)
{
    return PFalse;
}

PBoolean PSoundChannelPortAudio::PlayFile(const PFilePath & filename, PBoolean wait)
{
    return PFalse;
}

PBoolean PSoundChannelPortAudio::HasPlayCompleted()
{
    return PTrue;
}

PBoolean PSoundChannelPortAudio::WaitForPlayCompletion()
{
    return PTrue;
}

PBoolean PSoundChannelPortAudio::RecordSound(PSound & sound)
{
    return PFalse;
}

PBoolean PSoundChannelPortAudio::RecordFile(const PFilePath & filename)
{
    return PFalse;
}

PBoolean PSoundChannelPortAudio::StartRecording()
{
    return PTrue;
}

PBoolean PSoundChannelPortAudio::IsRecordBufferFull()
{
    return PFalse;
}

PBoolean PSoundChannelPortAudio::AreAllRecordBuffersFull()
{
    return PFalse;
}

PBoolean PSoundChannelPortAudio::WaitForRecordBufferFull()
{
    return PTrue;
}

PBoolean PSoundChannelPortAudio::WaitForAllRecordBuffersFull()
{
    return PTrue;
}

PBoolean PSoundChannelPortAudio::Abort()
{
    if (mStream != NULL) {
        Pa_AbortStream(mStream);
    }
    return PTrue;
}

///////////////////////////////////////////////////////////////////////////////
// Volume (not directly supported by PortAudio, would need platform-specific code)

PBoolean PSoundChannelPortAudio::SetVolume(unsigned newVal)
{
    PTRACE(6, "PortAudio\tSetVolume: " << newVal << " (not implemented)");
    return PTrue;  // Pretend success
}

PBoolean PSoundChannelPortAudio::GetVolume(unsigned & devVol)
{
    devVol = 100;  // Always return max
    return PTrue;
}
