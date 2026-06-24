/*
 * sound_portaudio.h
 *
 * PortAudio sound driver for PTLib
 *
 * Portable Windows Library
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

#ifndef _SOUND_PORTAUDIO_H
#define _SOUND_PORTAUDIO_H

#include <ptlib.h>
#include <ptlib/sound.h>
#include <portaudio.h>

class PSoundChannelPortAudio : public PSoundChannel
{
public:
    PSoundChannelPortAudio();
    PSoundChannelPortAudio(const PString &device,
                           PSoundChannel::Directions dir,
                           unsigned numChannels,
                           unsigned sampleRate,
                           unsigned bitsPerSample);
    ~PSoundChannelPortAudio();

    static PStringArray GetDeviceNames(PSoundChannel::Directions dir = Player);
    static PString GetDefaultDevice(PSoundChannel::Directions dir);

    PBoolean Open(const PString & device,
                  Directions dir,
                  unsigned numChannels,
                  unsigned sampleRate,
                  unsigned bitsPerSample);
    PBoolean Setup();
    PBoolean Close();
    PBoolean IsOpen() const;
    PBoolean Write(const void * buf, PINDEX len);
    PBoolean Read(void * buf, PINDEX len);
    PBoolean SetFormat(unsigned numChannels,
                       unsigned sampleRate,
                       unsigned bitsPerSample);
    unsigned GetChannels() const;
    unsigned GetSampleRate() const;
    unsigned GetSampleSize() const;
    PBoolean SetBuffers(PINDEX size, PINDEX count);
    PBoolean GetBuffers(PINDEX & size, PINDEX & count);
    PBoolean PlaySound(const PSound & sound, PBoolean wait);
    PBoolean PlayFile(const PFilePath & filename, PBoolean wait);
    PBoolean HasPlayCompleted();
    PBoolean WaitForPlayCompletion();
    PBoolean RecordSound(PSound & sound);
    PBoolean RecordFile(const PFilePath & filename);
    PBoolean StartRecording();
    PBoolean IsRecordBufferFull();
    PBoolean AreAllRecordBuffersFull();
    PBoolean WaitForRecordBufferFull();
    PBoolean WaitForAllRecordBuffersFull();
    PBoolean Abort();
    PBoolean SetVolume(unsigned newVal);
    PBoolean GetVolume(unsigned &devVol);

protected:
    void Construct();
    PaDeviceIndex GetDeviceIndex(const PString & device, Directions dir);

    unsigned mNumChannels;
    unsigned mSampleRate;
    unsigned mBitsPerSample;
    Directions mDirection;
    PString mDevice;
    
    PINDEX mBufferSize;
    PINDEX mBufferCount;

    PaStream *mStream;
    PaDeviceIndex mDeviceIndex;
    
    // Circular buffer for non-blocking I/O
    PBYTEArray mCircularBuffer;
    PINDEX mReadPos;
    PINDEX mWritePos;
    PINDEX mBufferedBytes;
    
    PMutex mMutex;
    
    static bool sInitialized;
    static PMutex sInitMutex;
    static void Initialize();
    static void Terminate();
};

#endif // _SOUND_PORTAUDIO_H
