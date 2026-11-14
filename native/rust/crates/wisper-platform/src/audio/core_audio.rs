use super::{CaptureError, Handoff, Shared, MAX_SECONDS};
use coreaudio_sys::*;
use std::{
    ffi::c_void,
    mem::{size_of, MaybeUninit},
    ptr,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
};

const MAX_CALLBACK_FRAMES: usize = 8192;
static DEVICE_OWNED: AtomicBool = AtomicBool::new(false);

struct CallbackState {
    unit: AudioUnit,
    buffer: Vec<f32>,
    channels: usize,
    handoff: Handoff,
}

pub(super) struct InputStream {
    unit: AudioUnit,
    state: Option<Box<CallbackState>>,
    shared: Arc<Shared>,
    rate: u32,
    channels: usize,
    monitor: DeviceMonitor,
    initialized: bool,
    playing: bool,
}

#[derive(Clone, Copy)]
pub(super) struct DeviceMonitor {
    device: AudioDeviceID,
    nominal_rate: f64,
}

impl DeviceMonitor {
    pub(super) fn unchanged(self) -> bool {
        device_property::<u32>(self.device, kAudioDevicePropertyDeviceIsAlive).ok() == Some(1)
            && device_property::<f64>(self.device, kAudioDevicePropertyNominalSampleRate).ok()
                == Some(self.nominal_rate)
            && device_property::<AudioDeviceID>(
                kAudioObjectSystemObject,
                kAudioHardwarePropertyDefaultInputDevice,
            )
            .ok()
                == Some(self.device)
    }
}

fn check(status: OSStatus) -> Result<(), CaptureError> {
    if status == 0 {
        Ok(())
    } else {
        Err(CaptureError::DeviceFailure)
    }
}

fn device_property<Value: Copy>(
    object: AudioObjectID,
    selector: AudioObjectPropertySelector,
) -> Result<Value, CaptureError> {
    let address = AudioObjectPropertyAddress {
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
    };
    let mut value = MaybeUninit::<Value>::uninit();
    let mut bytes = size_of::<Value>() as u32;
    check(unsafe {
        AudioObjectGetPropertyData(
            object,
            &address,
            0,
            ptr::null(),
            &mut bytes,
            value.as_mut_ptr().cast(),
        )
    })?;
    if bytes as usize != size_of::<Value>() {
        return Err(CaptureError::DeviceFailure);
    }
    Ok(unsafe { value.assume_init() })
}

impl InputStream {
    pub(super) fn prepare(shared: Arc<Shared>) -> Result<Self, CaptureError> {
        if DEVICE_OWNED.swap(true, Ordering::AcqRel) {
            return Err(CaptureError::DeviceFailure);
        }
        let description = AudioComponentDescription {
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0,
        };
        let component = unsafe { AudioComponentFindNext(ptr::null_mut(), &description) };
        let mut unit = ptr::null_mut();
        if component.is_null()
            || unsafe { AudioComponentInstanceNew(component, &mut unit) } != 0
            || unit.is_null()
        {
            DEVICE_OWNED.store(false, Ordering::Release);
            return Err(CaptureError::DeviceFailure);
        }
        let mut stream = Self {
            unit,
            state: None,
            shared,
            rate: 0,
            channels: 0,
            monitor: DeviceMonitor {
                device: 0,
                nominal_rate: 0.0,
            },
            initialized: false,
            playing: false,
        };
        let device = device_property::<AudioDeviceID>(
            kAudioObjectSystemObject,
            kAudioHardwarePropertyDefaultInputDevice,
        )?;
        if device == kAudioObjectUnknown {
            return Err(CaptureError::NoDevice);
        }
        stream.set_property(
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &1u32,
        )?;
        stream.set_property(
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &0u32,
        )?;
        stream.set_property(
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
        )?;
        let hardware = stream.property::<AudioStreamBasicDescription>(
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
        )?;
        let nominal_rate = device_property::<f64>(device, kAudioDevicePropertyNominalSampleRate)?;
        if !hardware.mSampleRate.is_finite()
            || hardware.mSampleRate.fract() != 0.0
            || !(8_000.0..=192_000.0).contains(&hardware.mSampleRate)
            || !(1..=32).contains(&hardware.mChannelsPerFrame)
            || hardware.mSampleRate != nominal_rate
        {
            return Err(CaptureError::UnsupportedFormat);
        }
        stream.rate = hardware.mSampleRate as u32;
        stream.channels = hardware.mChannelsPerFrame as usize;
        stream.monitor = DeviceMonitor {
            device,
            nominal_rate,
        };
        let format = AudioStreamBasicDescription {
            mSampleRate: hardware.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: hardware.mChannelsPerFrame * 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: hardware.mChannelsPerFrame * 4,
            mChannelsPerFrame: hardware.mChannelsPerFrame,
            mBitsPerChannel: 32,
            mReserved: 0,
        };
        stream.set_property(
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &format,
        )?;
        stream.set_property(
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &(MAX_CALLBACK_FRAMES as u32),
        )?;
        stream.set_property(
            kAudioUnitProperty_ShouldAllocateBuffer,
            kAudioUnitScope_Output,
            1,
            &0u32,
        )?;
        Ok(stream)
    }

    fn property<Value: Copy>(
        &self,
        property: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
    ) -> Result<Value, CaptureError> {
        let mut value = MaybeUninit::<Value>::uninit();
        let mut bytes = size_of::<Value>() as u32;
        check(unsafe {
            AudioUnitGetProperty(
                self.unit,
                property,
                scope,
                element,
                value.as_mut_ptr().cast(),
                &mut bytes,
            )
        })?;
        if bytes as usize != size_of::<Value>() {
            return Err(CaptureError::DeviceFailure);
        }
        Ok(unsafe { value.assume_init() })
    }

    fn set_property<Value>(
        &self,
        property: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        value: &Value,
    ) -> Result<(), CaptureError> {
        check(unsafe {
            AudioUnitSetProperty(
                self.unit,
                property,
                scope,
                element,
                (value as *const Value).cast(),
                size_of::<Value>() as u32,
            )
        })
    }

    pub(super) fn rate(&self) -> u32 {
        self.rate
    }
    pub(super) fn monitor(&self) -> DeviceMonitor {
        self.monitor
    }

    pub(super) fn attach(&mut self, producer: rtrb::Producer<f32>) -> Result<(), CaptureError> {
        let mut state = Box::new(CallbackState {
            unit: self.unit,
            buffer: vec![0.0; MAX_CALLBACK_FRAMES * self.channels],
            channels: self.channels,
            handoff: Handoff {
                producer,
                shared: self.shared.clone(),
                accepted: 0,
                frame_limit: self.rate as usize * MAX_SECONDS,
            },
        });
        let callback = AURenderCallbackStruct {
            inputProc: Some(input_callback),
            inputProcRefCon: (&mut *state as *mut CallbackState).cast(),
        };
        self.state = Some(state);
        self.set_property(
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callback,
        )?;
        check(unsafe { AudioUnitInitialize(self.unit) })?;
        self.initialized = true;
        Ok(())
    }

    pub(super) fn start(&mut self) -> Result<(), CaptureError> {
        if self.state.is_none() || !self.initialized {
            return Err(CaptureError::DeviceFailure);
        }
        if !self.monitor.unchanged() {
            return Err(CaptureError::DeviceFailure);
        }
        check(unsafe { AudioOutputUnitStart(self.unit) })?;
        self.playing = true;
        Ok(())
    }

    pub(super) fn stop(&mut self) -> Result<(), CaptureError> {
        if self.playing {
            check(unsafe { AudioOutputUnitStop(self.unit) })?;
            self.playing = false;
        }
        Ok(())
    }
}

impl Drop for InputStream {
    fn drop(&mut self) {
        if self.stop().is_err() {
            self.shared.fail(3);
        }
        if self.initialized && unsafe { AudioUnitUninitialize(self.unit) } != 0 {
            self.shared.fail(3);
        }
        if unsafe { AudioComponentInstanceDispose(self.unit) } != 0 {
            self.shared.fail(3);
            if let Some(state) = self.state.take() {
                let _ = Box::into_raw(state);
            }
            return;
        }
        DEVICE_OWNED.store(false, Ordering::Release);
    }
}

unsafe extern "C" fn input_callback(
    context: *mut c_void,
    flags: *mut AudioUnitRenderActionFlags,
    timestamp: *const AudioTimeStamp,
    _bus: u32,
    frames: u32,
    _output: *mut AudioBufferList,
) -> OSStatus {
    if context.is_null() {
        return -50;
    }
    let state = unsafe { &mut *context.cast::<CallbackState>() };
    if state.handoff.shared.cancel.load(Ordering::Relaxed)
        || state.handoff.shared.limit.load(Ordering::Relaxed)
        || state.handoff.shared.failure.load(Ordering::Relaxed) != 0
    {
        return 0;
    }
    if frames as usize > MAX_CALLBACK_FRAMES || flags.is_null() || timestamp.is_null() {
        state.handoff.shared.fail(3);
        return -50;
    }
    let sample_count = frames as usize * state.channels;
    let mut buffers = AudioBufferList {
        mNumberBuffers: 1,
        mBuffers: [AudioBuffer {
            mNumberChannels: state.channels as u32,
            mDataByteSize: (sample_count * 4) as u32,
            mData: state.buffer.as_mut_ptr().cast(),
        }],
    };
    let status = unsafe { AudioUnitRender(state.unit, flags, timestamp, 1, frames, &mut buffers) };
    if status != 0 {
        state.handoff.shared.fail(3);
        return status;
    }
    if buffers.mNumberBuffers != 1
        || buffers.mBuffers[0].mNumberChannels as usize != state.channels
        || buffers.mBuffers[0].mDataByteSize as usize != sample_count * 4
        || buffers.mBuffers[0].mData != state.buffer.as_mut_ptr().cast()
    {
        state.handoff.shared.fail(2);
        return -50;
    }
    for frame in state.buffer[..sample_count].chunks_exact(state.channels) {
        if !state.handoff.push(frame) {
            break;
        }
    }
    0
}
