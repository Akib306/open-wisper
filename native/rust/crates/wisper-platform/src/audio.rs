use rubato::{
    Resampler, SincFixedIn, SincInterpolationParameters, SincInterpolationType, WindowFunction,
};
use std::sync::{
    atomic::{AtomicBool, AtomicU8, Ordering},
    Arc,
};

pub const OUTPUT_RATE: u32 = 16_000;
pub const MAX_SECONDS: usize = 300;
const CHUNK: usize = 1024;
const RING_CAPACITY: usize = 65_536;

#[cfg(target_os = "macos")]
mod core_audio;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CaptureError {
    Unsupported,
    PermissionRequired,
    NoDevice,
    UnsupportedFormat,
    DeviceFailure,
    Overflow,
    InvalidSamples,
    Conversion,
    WorkerFailure,
    Cancelled,
}

impl std::fmt::Display for CaptureError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{self:?}")
    }
}

impl std::error::Error for CaptureError {}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CaptureStatus {
    Recording,
    DurationLimit,
    Failed(CaptureError),
}

pub struct CapturedAudio {
    pub samples: Vec<i16>,
    pub duration_limit_reached: bool,
}

struct Converter {
    resampler: SincFixedIn<f32>,
    pending: Vec<f32>,
    output: Vec<i16>,
    delay: usize,
    source_frames: usize,
    source_rate: u32,
}

impl Converter {
    fn new(source_rate: u32) -> Result<Self, CaptureError> {
        if !(8_000..=192_000).contains(&source_rate) {
            return Err(CaptureError::UnsupportedFormat);
        }
        let resampler = SincFixedIn::new(
            OUTPUT_RATE as f64 / source_rate as f64,
            1.0,
            SincInterpolationParameters {
                sinc_len: 256,
                f_cutoff: 0.95,
                interpolation: SincInterpolationType::Cubic,
                oversampling_factor: 256,
                window: WindowFunction::BlackmanHarris2,
            },
            CHUNK,
            1,
        )
        .map_err(|_| CaptureError::Conversion)?;
        let divisor = greatest_common_divisor(source_rate, OUTPUT_RATE);
        let prime_frames = source_rate / divisor;
        let delay = (OUTPUT_RATE / divisor - 1) as usize;
        let mut converter = Self {
            resampler,
            pending: Vec::with_capacity(CHUNK),
            output: Vec::with_capacity(OUTPUT_RATE as usize * MAX_SECONDS),
            delay,
            source_frames: 0,
            source_rate,
        };
        for _ in 0..prime_frames {
            converter.pending.push(0.0);
            if converter.pending.len() == CHUNK {
                converter.process()?;
            }
        }
        Ok(converter)
    }

    fn push(&mut self, sample: f32) -> Result<(), CaptureError> {
        if !sample.is_finite() {
            return Err(CaptureError::InvalidSamples);
        }
        if self.source_frames >= self.source_rate as usize * MAX_SECONDS {
            return Err(CaptureError::Overflow);
        }
        self.source_frames += 1;
        self.pending.push(sample.clamp(-1.0, 1.0));
        if self.pending.len() == CHUNK {
            self.process()?;
        }
        Ok(())
    }

    fn process(&mut self) -> Result<(), CaptureError> {
        self.pending.resize(CHUNK, 0.0);
        let converted = self
            .resampler
            .process(&[&self.pending[..]], None)
            .map_err(|_| CaptureError::Conversion)?;
        for &sample in &converted[0] {
            if self.delay > 0 {
                self.delay -= 1;
            } else if self.output.len() < OUTPUT_RATE as usize * MAX_SECONDS {
                self.output.push(pcm16(sample));
            }
        }
        self.pending.clear();
        Ok(())
    }

    fn finish(mut self) -> Result<Vec<i16>, CaptureError> {
        let expected = self.source_frames * OUTPUT_RATE as usize / self.source_rate as usize;
        if !self.pending.is_empty() {
            self.process()?;
        }
        while self.output.len() < expected {
            self.process()?;
        }
        self.output.truncate(expected);
        Ok(self.output)
    }
}

fn greatest_common_divisor(mut left: u32, mut right: u32) -> u32 {
    while right != 0 {
        let remainder = left % right;
        left = right;
        right = remainder;
    }
    left
}

fn pcm16(sample: f32) -> i16 {
    (sample.clamp(-1.0, 1.0) * 32768.0)
        .round()
        .clamp(-32768.0, 32767.0) as i16
}

fn downmix(frame: &[f32]) -> Result<f32, CaptureError> {
    if frame.is_empty() || frame.len() > 32 || frame.iter().any(|sample| !sample.is_finite()) {
        return Err(CaptureError::InvalidSamples);
    }
    Ok(frame
        .iter()
        .map(|sample| sample.clamp(-1.0, 1.0))
        .sum::<f32>()
        / frame.len() as f32)
}

struct Shared {
    failure: AtomicU8,
    limit: AtomicBool,
    stop: AtomicBool,
    cancel: AtomicBool,
}

impl Shared {
    fn new() -> Self {
        Self {
            failure: AtomicU8::new(0),
            limit: AtomicBool::new(false),
            stop: AtomicBool::new(false),
            cancel: AtomicBool::new(false),
        }
    }

    fn fail(&self, code: u8) {
        let _ = self
            .failure
            .compare_exchange(0, code, Ordering::AcqRel, Ordering::Acquire);
    }

    fn error(&self) -> Option<CaptureError> {
        match self.failure.load(Ordering::Acquire) {
            0 => None,
            1 => Some(CaptureError::Overflow),
            2 => Some(CaptureError::InvalidSamples),
            3 => Some(CaptureError::DeviceFailure),
            _ => Some(CaptureError::Conversion),
        }
    }
}

struct Handoff {
    producer: rtrb::Producer<f32>,
    shared: Arc<Shared>,
    accepted: usize,
    frame_limit: usize,
}

impl Handoff {
    fn push(&mut self, frame: &[f32]) -> bool {
        if self.shared.failure.load(Ordering::Relaxed) != 0
            || self.shared.limit.load(Ordering::Relaxed)
            || self.shared.cancel.load(Ordering::Relaxed)
        {
            return false;
        }
        if self.accepted >= self.frame_limit {
            self.shared.limit.store(true, Ordering::Release);
            return false;
        }
        let mono = match downmix(frame) {
            Ok(mono) => mono,
            Err(_) => {
                self.shared.fail(2);
                return false;
            }
        };
        if self.producer.push(mono).is_err() {
            self.shared.fail(1);
            return false;
        }
        self.accepted += 1;
        if self.accepted == self.frame_limit {
            self.shared.limit.store(true, Ordering::Release);
        }
        true
    }
}

pub struct CaptureSession {
    #[cfg(target_os = "macos")]
    stream: Option<core_audio::InputStream>,
    shared: Arc<Shared>,
    worker: Option<std::thread::JoinHandle<Result<Vec<i16>, CaptureError>>>,
}

impl CaptureSession {
    pub fn start() -> Result<Self, CaptureError> {
        #[cfg(target_os = "macos")]
        {
            native::start()
        }
        #[cfg(not(target_os = "macos"))]
        {
            Err(CaptureError::Unsupported)
        }
    }

    pub fn status(&self) -> CaptureStatus {
        if let Some(error) = self.shared.error() {
            CaptureStatus::Failed(error)
        } else if self.shared.limit.load(Ordering::Acquire) {
            CaptureStatus::DurationLimit
        } else {
            CaptureStatus::Recording
        }
    }

    pub fn stop(mut self) -> Result<CapturedAudio, CaptureError> {
        self.teardown();
        let result = self
            .worker
            .take()
            .ok_or(CaptureError::WorkerFailure)?
            .join()
            .map_err(|_| CaptureError::WorkerFailure)?;
        if let Some(error) = self.shared.error() {
            return Err(error);
        }
        Ok(CapturedAudio {
            samples: result?,
            duration_limit_reached: self.shared.limit.load(Ordering::Acquire),
        })
    }

    pub fn cancel(mut self) -> Result<(), CaptureError> {
        self.shared.cancel.store(true, Ordering::Release);
        self.teardown();
        if let Some(worker) = self.worker.take() {
            match worker.join().map_err(|_| CaptureError::WorkerFailure)? {
                Ok(_) | Err(CaptureError::Cancelled) => {}
                Err(error) => return Err(error),
            }
        }
        match self.shared.error() {
            Some(error) => Err(error),
            None => Ok(()),
        }
    }

    fn teardown(&mut self) {
        #[cfg(target_os = "macos")]
        if let Some(mut stream) = self.stream.take() {
            if stream.stop().is_err() {
                self.shared.fail(3);
            }
            drop(stream);
        }
        self.shared.stop.store(true, Ordering::Release);
    }
}

impl Drop for CaptureSession {
    fn drop(&mut self) {
        self.shared.cancel.store(true, Ordering::Release);
        self.teardown();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

#[cfg(target_os = "macos")]
mod native {
    use super::*;

    pub(super) fn start() -> Result<CaptureSession, CaptureError> {
        if crate::permissions::microphone_status()
            != crate::permissions::MicrophoneStatus::Authorized
        {
            return Err(CaptureError::PermissionRequired);
        }
        let shared = Arc::new(Shared::new());
        let mut stream = core_audio::InputStream::prepare(shared.clone())?;
        let monitor = stream.monitor();
        let mut converter = Converter::new(stream.rate())?;
        let (producer, mut consumer) = rtrb::RingBuffer::new(RING_CAPACITY);
        stream.attach(producer)?;
        let worker_shared = shared.clone();
        let worker = std::thread::Builder::new()
            .name("wisper-audio".into())
            .spawn(move || {
                let mut last_frame = std::time::Instant::now();
                let mut last_monitor = last_frame;
                loop {
                    if worker_shared.cancel.load(Ordering::Acquire) {
                        return Err(CaptureError::Cancelled);
                    }
                    let mut received = false;
                    while let Ok(sample) = consumer.pop() {
                        received = true;
                        if let Err(error) = converter.push(sample) {
                            worker_shared.fail(4);
                            return Err(error);
                        }
                    }
                    if received {
                        last_frame = std::time::Instant::now();
                    }
                    if worker_shared.stop.load(Ordering::Acquire) {
                        while let Ok(sample) = consumer.pop() {
                            converter.push(sample)?;
                        }
                        return converter.finish();
                    }
                    if !worker_shared.limit.load(Ordering::Acquire)
                        && last_frame.elapsed() > std::time::Duration::from_secs(3)
                    {
                        worker_shared.fail(3);
                    }
                    if last_monitor.elapsed() > std::time::Duration::from_millis(100) {
                        if !monitor.unchanged()
                            || crate::permissions::microphone_status()
                                != crate::permissions::MicrophoneStatus::Authorized
                        {
                            worker_shared.fail(3);
                        }
                        last_monitor = std::time::Instant::now();
                    }
                    if let Some(error) = worker_shared.error() {
                        return Err(error);
                    }
                    std::thread::sleep(std::time::Duration::from_millis(1));
                }
            })
            .map_err(|_| CaptureError::WorkerFailure)?;
        let mut session = CaptureSession {
            stream: Some(stream),
            shared: shared.clone(),
            worker: Some(worker),
        };
        session.stream.as_mut().unwrap().start()?;
        Ok(session)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn channel_and_sample_bounds() {
        assert!(downmix(&[]).is_err());
        assert!(downmix(&[0.0; 33]).is_err());
        assert!(downmix(&[f32::NAN]).is_err());
        assert_eq!(downmix(&[2.0, 0.0]).unwrap(), 0.5);
        assert_eq!(downmix(&[1.0, -1.0]).unwrap(), 0.0);
        assert_eq!(pcm16(-2.0), i16::MIN);
        assert_eq!(pcm16(2.0), i16::MAX);
    }

    #[test]
    fn handoff_preserves_order_and_reports_overflow() {
        let shared = Arc::new(Shared::new());
        let (producer, mut consumer) = rtrb::RingBuffer::new(2);
        let mut handoff = Handoff {
            producer,
            shared: shared.clone(),
            accepted: 0,
            frame_limit: 10,
        };
        assert!(handoff.push(&[0.25]));
        assert!(handoff.push(&[0.5]));
        assert!(!handoff.push(&[0.75]));
        assert_eq!(shared.error(), Some(CaptureError::Overflow));
        assert_eq!(consumer.pop().unwrap(), 0.25);
        assert_eq!(consumer.pop().unwrap(), 0.5);
        assert!(consumer.pop().is_err());
        assert!(!handoff.push(&[0.75]));
    }

    #[test]
    fn handoff_stops_at_duration_limit_and_cancel() {
        let shared = Arc::new(Shared::new());
        let (producer, mut consumer) = rtrb::RingBuffer::new(4);
        let mut handoff = Handoff {
            producer,
            shared: shared.clone(),
            accepted: 0,
            frame_limit: 2,
        };
        assert!(handoff.push(&[0.1]));
        assert!(handoff.push(&[0.2]));
        assert!(!handoff.push(&[0.3]));
        assert!(shared.limit.load(Ordering::Acquire));
        assert_eq!(handoff.accepted, 2);
        assert!(shared.error().is_none());
        assert!(consumer.pop().is_ok());
        assert!(consumer.pop().is_ok());
        assert!(consumer.pop().is_err());
        let shared = Arc::new(Shared::new());
        let (producer, mut consumer) = rtrb::RingBuffer::new(4);
        let mut handoff = Handoff {
            producer,
            shared: shared.clone(),
            accepted: 0,
            frame_limit: 2,
        };
        shared.cancel.store(true, Ordering::Release);
        assert!(!handoff.push(&[0.1]));
        assert!(consumer.pop().is_err());
    }

    #[test]
    fn exact_length_and_final_flush() {
        for rate in [8_000, 16_000, 44_100, 48_000, 192_000] {
            for frames in [0, 1, 17, 1023, 1024, 2051] {
                let mut converter = Converter::new(rate).unwrap();
                for _ in 0..frames {
                    converter.push(0.25).unwrap();
                }
                assert_eq!(
                    converter.finish().unwrap().len(),
                    frames * OUTPUT_RATE as usize / rate as usize
                );
            }
        }
    }

    fn tone_rms(frequency: f32) -> f64 {
        let mut converter = Converter::new(48_000).unwrap();
        for frame in 0..48_000 {
            converter
                .push((frame as f32 * frequency * std::f32::consts::TAU / 48_000.0).sin() * 0.5)
                .unwrap();
        }
        let samples = converter.finish().unwrap();
        let middle = &samples[1000..15000];
        (middle
            .iter()
            .map(|sample| (*sample as f64).powi(2))
            .sum::<f64>()
            / middle.len() as f64)
            .sqrt()
    }

    #[test]
    fn anti_alias_filter_rejects_above_nyquist() {
        assert!(tone_rms(12_000.0) < tone_rms(1_000.0) * 0.02);
    }

    #[test]
    fn final_partial_chunk_is_not_discarded() {
        for rate in [8_000, 16_000, 44_100, 48_000, 96_000, 192_000] {
            let mut converter = Converter::new(rate).unwrap();
            for _ in 0..2048 {
                converter.push(0.0).unwrap();
            }
            for _ in 0..37 {
                converter.push(0.5).unwrap();
            }
            let output = converter.finish().unwrap();
            assert!(
                output[output.len() - 10..]
                    .iter()
                    .any(|sample| *sample > 1000),
                "rate {rate}"
            );
        }
    }

    #[test]
    fn output_timeline_is_aligned_across_rational_rates() {
        for rate in [8_000, 16_000, 44_099, 44_100, 48_000, 96_000, 192_000] {
            let mut converter = Converter::new(rate).unwrap();
            let leading_frames = rate as usize / 10;
            for _ in 0..leading_frames {
                converter.push(0.0).unwrap();
            }
            for _ in 0..leading_frames {
                converter.push(0.5).unwrap();
            }
            let output = converter.finish().unwrap();
            let onset = output.iter().position(|sample| *sample > 8192).unwrap();
            let expected = leading_frames * OUTPUT_RATE as usize / rate as usize;
            assert!(
                onset.abs_diff(expected) <= 2,
                "rate {rate}, onset {onset}, expected {expected}"
            );
        }
    }

    #[test]
    fn impulses_preserve_positions_at_both_recording_boundaries() {
        let mut misaligned = Vec::new();
        for rate in [8_000, 16_000, 44_099, 44_100, 48_000, 96_000, 192_000] {
            let frames = rate as usize / 5;
            for impulse_frame in [0, rate as usize / 100, frames - 2] {
                let mut converter = Converter::new(rate).unwrap();
                for frame in 0..frames {
                    converter
                        .push(if frame == impulse_frame { 1.0 } else { 0.0 })
                        .unwrap();
                }
                let output = converter.finish().unwrap();
                let peak = output
                    .iter()
                    .enumerate()
                    .max_by_key(|(_, sample)| i32::from(**sample).abs())
                    .unwrap();
                let expected = impulse_frame * OUTPUT_RATE as usize / rate as usize;
                if peak.0.abs_diff(expected) > 2 || i32::from(*peak.1).abs() <= 100 {
                    misaligned.push(format!(
                        "rate {rate}, impulse {impulse_frame}, peak {}, expected {expected}, amplitude {}",
                        peak.0, peak.1
                    ));
                }
            }
        }
        assert!(misaligned.is_empty(), "{}", misaligned.join("; "));
    }

    #[test]
    fn conversion_keeps_chronological_sections() {
        let mut converter = Converter::new(44_100).unwrap();
        for _ in 0..44_100 {
            converter.push(0.0).unwrap();
        }
        for _ in 0..44_100 {
            converter.push(0.5).unwrap();
        }
        let output = converter.finish().unwrap();
        assert!(output[1000..15_000].iter().all(|sample| *sample == 0));
        assert!(output[17_000..31_000].iter().all(|sample| *sample > 15_000));
    }
}
