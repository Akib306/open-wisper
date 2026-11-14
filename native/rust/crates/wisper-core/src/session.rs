#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub struct Generation(u64);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Phase {
    Idle,
    Starting,
    Recording,
    Stopping,
    Transcribing,
    Ready,
}

#[derive(Debug)]
pub struct SessionCoordinator {
    next: u64,
    current: Option<Generation>,
    phase: Phase,
    delivery_available: bool,
}

impl Default for SessionCoordinator {
    fn default() -> Self {
        Self {
            next: 0,
            current: None,
            phase: Phase::Idle,
            delivery_available: false,
        }
    }
}

impl SessionCoordinator {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn phase(&self) -> Phase {
        self.phase
    }
    pub fn generation(&self) -> Option<Generation> {
        self.current
    }
    pub fn start(&mut self) -> Generation {
        if let Some(generation) = self.current {
            return generation;
        }
        self.next = self
            .next
            .checked_add(1)
            .expect("session generation exhausted");
        let generation = Generation(self.next);
        self.current = Some(generation);
        self.phase = Phase::Starting;
        generation
    }
    pub fn recording_started(&mut self, generation: Generation) -> bool {
        self.transition(generation, Phase::Starting, Phase::Recording)
    }
    pub fn stop(&mut self) -> Option<Generation> {
        let generation = self.current?;
        if matches!(self.phase, Phase::Starting | Phase::Recording) {
            self.phase = Phase::Stopping;
        }
        Some(generation)
    }
    pub fn audio_ready(&mut self, generation: Generation) -> bool {
        self.transition(generation, Phase::Stopping, Phase::Transcribing)
    }
    pub fn transcription_ready(&mut self, generation: Generation) -> bool {
        if self.transition(generation, Phase::Transcribing, Phase::Ready) {
            self.delivery_available = true;
            true
        } else {
            false
        }
    }
    pub fn authorize_delivery(&mut self, generation: Generation) -> bool {
        if self.current == Some(generation) && self.phase == Phase::Ready && self.delivery_available
        {
            self.delivery_available = false;
            true
        } else {
            false
        }
    }
    pub fn finish(&mut self, generation: Generation) -> bool {
        if self.current != Some(generation) {
            return false;
        }
        self.cancel();
        true
    }
    pub fn cancel(&mut self) {
        self.current = None;
        self.phase = Phase::Idle;
        self.delivery_available = false;
    }
    fn transition(&mut self, generation: Generation, from: Phase, to: Phase) -> bool {
        if self.current == Some(generation) && self.phase == from {
            self.phase = to;
            true
        } else {
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn stale_and_duplicate_results_are_rejected() {
        let mut session = SessionCoordinator::new();
        let first = session.start();
        assert_eq!(session.start(), first);
        assert_eq!(session.stop(), Some(first));
        assert_eq!(session.stop(), Some(first));
        session.cancel();
        let second = session.start();
        assert!(!session.recording_started(first));
        assert!(session.recording_started(second));
        session.stop();
        assert!(session.audio_ready(second));
        assert!(session.transcription_ready(second));
        assert!(!session.transcription_ready(second));
        assert!(session.authorize_delivery(second));
        assert!(!session.authorize_delivery(second));
        session.cancel();
        assert!(!session.authorize_delivery(second));
    }
}
