//! Audio duration and 48-bar normalized peak waveform extraction via `symphonia`.
//!
//! Mirrors `MediaPipeline.audio(_:)` in macOS `MediaPipeline.swift`.

use std::fs::File;
use std::path::Path;

use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

pub const WAVEFORM_BARS: usize = 48;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct AudioAnalysis {
    pub duration_seconds: Option<f64>,
    pub waveform_peaks: Vec<f32>,
}

/// Decodes an audio file with `symphonia` and samples 48 normalized peak bars in `[0.0, 1.0]`.
pub fn analyze_audio(path: &Path) -> AudioAnalysis {
    let Ok(file) = File::open(path) else {
        return AudioAnalysis::default();
    };
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }

    let Ok(probed) = symphonia::default::get_probe().format(
        &hint,
        mss,
        &FormatOptions::default(),
        &MetadataOptions::default(),
    ) else {
        return AudioAnalysis::default();
    };

    let mut format = probed.format;
    let Some(track) = format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
        .cloned()
    else {
        return AudioAnalysis::default();
    };

    let track_id = track.id;
    let sample_rate = track.codec_params.sample_rate.unwrap_or(0);
    let known_frames = track.codec_params.n_frames;
    let header_duration = match (known_frames, sample_rate) {
        (Some(frames), sr) if sr > 0 && frames > 0 => Some(frames as f64 / sr as f64),
        _ => None,
    };

    let Ok(mut decoder) =
        symphonia::default::get_codecs().make(&track.codec_params, &DecoderOptions::default())
    else {
        return AudioAnalysis {
            duration_seconds: header_duration,
            waveform_peaks: Vec::new(),
        };
    };

    let mut packet_peaks: Vec<f32> = Vec::with_capacity(4096);
    let mut total_frames: u64 = 0;
    let mut decoded_sample_rate = sample_rate;
    let mut sample_buf: Option<SampleBuffer<f32>> = None;

    loop {
        let packet = match format.next_packet() {
            Ok(p) => p,
            Err(SymphoniaError::IoError(_)) | Err(SymphoniaError::ResetRequired) => break,
            Err(_) => break,
        };
        if packet.track_id() != track_id {
            continue;
        }
        let decoded = match decoder.decode(&packet) {
            Ok(d) => d,
            Err(SymphoniaError::DecodeError(_)) => continue,
            Err(_) => break,
        };

        let spec = *decoded.spec();
        if decoded_sample_rate == 0 {
            decoded_sample_rate = spec.rate;
        }
        let frames = decoded.frames() as u64;
        total_frames = total_frames.saturating_add(frames);

        let buf = sample_buf
            .get_or_insert_with(|| SampleBuffer::<f32>::new(decoded.capacity() as u64, spec));
        if buf.capacity() < decoded.capacity() * spec.channels.count() {
            *buf = SampleBuffer::<f32>::new(decoded.capacity() as u64, spec);
        }
        buf.copy_interleaved_ref(decoded);
        let samples = buf.samples();
        if !samples.is_empty() && packet_peaks.len() < 8192 {
            // Subdivide large packets so short files still produce smooth 48-bar resolution.
            let chunks = if samples.len() > 2048 { 8 } else { 4 };
            let step = (samples.len() / chunks).max(1);
            for slice in samples.chunks(step) {
                let mut peak = 0.0_f32;
                for &s in slice {
                    let abs = s.abs().min(1.0);
                    if abs > peak {
                        peak = abs;
                    }
                }
                packet_peaks.push(peak);
                if packet_peaks.len() >= 8192 {
                    break;
                }
            }
        }
    }

    let duration_seconds = header_duration.or_else(|| {
        if decoded_sample_rate > 0 && total_frames > 0 {
            Some(total_frames as f64 / decoded_sample_rate as f64)
        } else {
            None
        }
    });

    let waveform_peaks = if packet_peaks.is_empty() {
        Vec::new()
    } else {
        let mut bars = vec![0.0_f32; WAVEFORM_BARS];
        let count = packet_peaks.len();
        for (idx, val) in packet_peaks.into_iter().enumerate() {
            let bin = ((idx * WAVEFORM_BARS) / count).min(WAVEFORM_BARS - 1);
            if val > bars[bin] {
                bars[bin] = val;
            }
        }
        bars
    };

    AudioAnalysis {
        duration_seconds,
        waveform_peaks,
    }
}
