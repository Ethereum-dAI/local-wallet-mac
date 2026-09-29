//! Drives the compiled `edw-tui` binary in a real pseudo-terminal, the way a person would:
//! type, wait for text on screen, press keys. `portable-pty` runs the process, and `vt100`
//! turns its output into the screen a terminal would show, which tests read and save.
//!
//! Optionally records the whole session: every change on screen becomes a frame, and
//! [`Tui::finish_recording`] encodes the frames to an MP4 (needs `rsvg-convert` and `ffmpeg`
//! on PATH).

use std::{
    io::{Read, Write},
    path::{Path, PathBuf},
    process::Command,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

use portable_pty::{Child, CommandBuilder, MasterPty, PtySize, native_pty_system};

struct Recorder {
    frames: Arc<Mutex<Vec<(Duration, String)>>>,
    stop: Arc<AtomicBool>,
    thread: JoinHandle<()>,
}

pub struct Tui {
    parser: Arc<Mutex<vt100::Parser>>,
    writer: Box<dyn Write + Send>,
    child: Box<dyn Child + Send + Sync>,
    _master: Box<dyn MasterPty + Send>,
    recorder: Option<Recorder>,
    pub rows: u16,
    pub cols: u16,
}

impl Tui {
    pub fn spawn(binary: &Path, env: &[(&str, String)], rows: u16, cols: u16) -> Self {
        let pair = native_pty_system()
            .openpty(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .expect("open a pty");
        let mut command = CommandBuilder::new(binary);
        command.env("TERM", "xterm-256color");
        for (key, value) in env {
            command.env(key, value);
        }
        let child = pair.slave.spawn_command(command).expect("spawn edw-tui");
        drop(pair.slave);

        let parser = Arc::new(Mutex::new(vt100::Parser::new(rows, cols, 0)));
        let mut reader = pair.master.try_clone_reader().expect("pty reader");
        let sink = parser.clone();
        thread::spawn(move || {
            let mut buffer = [0u8; 8192];
            while let Ok(n) = reader.read(&mut buffer) {
                if n == 0 {
                    break;
                }
                sink.lock().unwrap().process(&buffer[..n]);
            }
        });
        let writer = pair.master.take_writer().expect("pty writer");
        Self {
            parser,
            writer,
            child,
            _master: pair.master,
            recorder: None,
            rows,
            cols,
        }
    }

    /// Starts keeping a frame whenever the screen changes. Typing also slows down to a pace a
    /// viewer can follow.
    pub fn start_recording(&mut self) {
        let frames = Arc::new(Mutex::new(Vec::new()));
        let stop = Arc::new(AtomicBool::new(false));
        let (parser, sink, halt) = (self.parser.clone(), frames.clone(), stop.clone());
        let (rows, cols) = (self.rows, self.cols);
        let started = Instant::now();
        let thread = thread::spawn(move || {
            let mut last = String::new();
            while !halt.load(Ordering::Relaxed) {
                let svg = render_svg(&parser.lock().unwrap(), rows, cols);
                if svg != last {
                    sink.lock().unwrap().push((started.elapsed(), svg.clone()));
                    last = svg;
                }
                thread::sleep(Duration::from_millis(40));
            }
        });
        self.recorder = Some(Recorder {
            frames,
            stop,
            thread,
        });
    }

    /// Stops recording and writes `<dir>/<name>.mp4`, holding the last frame for a moment.
    /// Returns the file written, or `None` when nothing was being recorded.
    pub fn finish_recording(&mut self, dir: &Path, name: &str) -> Option<PathBuf> {
        let recorder = self.recorder.take()?;
        thread::sleep(Duration::from_millis(300)); // let the last draw land
        recorder.stop.store(true, Ordering::Relaxed);
        recorder.thread.join().unwrap();
        let frames = std::mem::take(&mut *recorder.frames.lock().unwrap());
        Some(encode(&frames, dir, name))
    }

    /// The screen as text, one line per row.
    pub fn screen(&self) -> String {
        let parser = self.parser.lock().unwrap();
        parser
            .screen()
            .rows(0, self.cols)
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// Waits until `predicate` holds for the screen; panics with the screen on timeout.
    pub fn wait_until(&self, what: &str, predicate: impl Fn(&str) -> bool) -> String {
        let deadline = Instant::now() + Duration::from_secs(60);
        loop {
            let screen = self.screen();
            if predicate(&screen) {
                return screen;
            }
            if Instant::now() > deadline {
                panic!("timed out waiting for {what}; the screen was:\n{screen}");
            }
            thread::sleep(Duration::from_millis(50));
        }
    }

    pub fn wait_for(&self, text: &str) -> String {
        self.wait_until(&format!("{text:?}"), |screen| screen.contains(text))
    }

    /// Types `text` one key at a time, as a person would.
    pub fn type_text(&mut self, text: &str) {
        let pause = if self.recorder.is_some() { 35 } else { 2 };
        for byte in text.bytes() {
            self.writer.write_all(&[byte]).unwrap();
            self.writer.flush().unwrap();
            thread::sleep(Duration::from_millis(pause));
        }
    }

    pub fn press(&mut self, key: &[u8]) {
        self.writer.write_all(key).unwrap();
        self.writer.flush().unwrap();
    }

    /// Types a message and presses Enter.
    pub fn submit(&mut self, text: &str) {
        self.type_text(text);
        if self.recorder.is_some() {
            thread::sleep(Duration::from_millis(400)); // a beat to read what was typed
        }
        self.press(b"\r");
    }

    /// A pause that only matters to someone watching the recording.
    pub fn linger(&self, millis: u64) {
        if self.recorder.is_some() {
            thread::sleep(Duration::from_millis(millis));
        }
    }

    /// Ctrl-C, then waits for the process to exit.
    pub fn quit(mut self) -> bool {
        self.press(&[0x03]);
        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline {
            if let Ok(Some(status)) = self.child.try_wait() {
                return status.success();
            }
            thread::sleep(Duration::from_millis(50));
        }
        let _ = self.child.kill();
        false
    }

    /// The screen as an SVG image with the terminal's colours, for people to look at.
    pub fn screenshot_svg(&self) -> String {
        render_svg(&self.parser.lock().unwrap(), self.rows, self.cols)
    }
}

const CELL_W: f32 = 8.4;
const CELL_H: f32 = 18.0;
const DEFAULT_FG: &str = "#d8dee9";
const DEFAULT_BG: &str = "#1c2128";

fn render_svg(parser: &vt100::Parser, rows: u16, cols: u16) -> String {
    let screen = parser.screen();
    let (width, height) = (cols as f32 * CELL_W, rows as f32 * CELL_H);
    let mut svg = format!(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{w}\" height=\"{h}\" viewBox=\"0 0 {w} {h}\">\n\
         <rect width=\"100%\" height=\"100%\" fill=\"{DEFAULT_BG}\"/>\n\
         <g font-family=\"Menlo, 'DejaVu Sans Mono', monospace\" font-size=\"14\" xml:space=\"preserve\">\n",
        w = width + 16.0,
        h = height + 16.0,
    );
    for row in 0..rows {
        for col in 0..cols {
            let Some(cell) = screen.cell(row, col) else {
                continue;
            };
            let (mut fg, mut bg) = (
                color(cell.fgcolor(), DEFAULT_FG),
                color(cell.bgcolor(), DEFAULT_BG),
            );
            if cell.inverse() {
                std::mem::swap(&mut fg, &mut bg);
            }
            let (x, y) = (8.0 + col as f32 * CELL_W, 8.0 + row as f32 * CELL_H);
            if bg != DEFAULT_BG {
                // A hair wider than the cell, so neighbouring backgrounds leave no seams.
                svg.push_str(&format!(
                    "<rect x=\"{x}\" y=\"{y}\" width=\"{}\" height=\"{}\" fill=\"{bg}\"/>\n",
                    CELL_W + 0.6,
                    CELL_H + 0.6
                ));
            }
            let text = cell.contents();
            if !text.trim().is_empty() {
                let weight = if cell.bold() {
                    " font-weight=\"bold\""
                } else {
                    ""
                };
                svg.push_str(&format!(
                    "<text x=\"{x}\" y=\"{}\" fill=\"{fg}\"{weight}>{}</text>\n",
                    y + CELL_H * 0.75,
                    escape(text)
                ));
            }
        }
    }
    if !screen.hide_cursor() {
        let (row, col) = screen.cursor_position();
        svg.push_str(&format!(
            "<rect x=\"{}\" y=\"{}\" width=\"{CELL_W}\" height=\"{CELL_H}\" fill=\"{DEFAULT_FG}\" opacity=\"0.7\"/>\n",
            8.0 + col as f32 * CELL_W,
            8.0 + row as f32 * CELL_H
        ));
    }
    svg.push_str("</g>\n</svg>\n");
    svg
}

/// Frames (time since start, SVG) → PNGs → an MP4, via rsvg-convert and ffmpeg.
fn encode(frames: &[(Duration, String)], dir: &Path, name: &str) -> PathBuf {
    assert!(!frames.is_empty(), "the recording has no frames");
    let work = dir.join(format!("{name}-frames"));
    let _ = std::fs::remove_dir_all(&work);
    std::fs::create_dir_all(&work).unwrap();

    // The concat demuxer shows each frame until the next one; the last is held for 3 s.
    let mut list = String::new();
    for (i, (at, svg)) in frames.iter().enumerate() {
        let (svg_path, png_path) = (
            work.join(format!("{i:05}.svg")),
            work.join(format!("{i:05}.png")),
        );
        std::fs::write(&svg_path, svg).unwrap();
        run("rsvg-convert", &["-o", path(&png_path), path(&svg_path)]);
        let until = frames
            .get(i + 1)
            .map_or(*at + Duration::from_secs(3), |(next, _)| *next);
        list.push_str(&format!(
            "file '{}'\nduration {:.3}\n",
            path(&png_path),
            (until - *at).as_secs_f64()
        ));
    }
    // The demuxer ignores the last duration unless the final file is listed once more.
    list.push_str(&format!(
        "file '{}'\n",
        path(&work.join(format!("{:05}.png", frames.len() - 1)))
    ));
    let list_path = work.join("frames.txt");
    std::fs::write(&list_path, list).unwrap();

    let out = dir.join(format!("{name}.mp4"));
    run(
        "ffmpeg",
        &[
            "-y",
            "-loglevel",
            "error",
            "-f",
            "concat",
            "-safe",
            "0",
            "-i",
            path(&list_path),
            // H.264 wants even dimensions and 4:2:0 chroma to play everywhere.
            "-vf",
            "scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p",
            "-r",
            "30",
            "-c:v",
            "libx264",
            "-crf",
            "20",
            "-movflags",
            "+faststart",
            path(&out),
        ],
    );
    out
}

fn path(p: &Path) -> &str {
    p.to_str().expect("utf-8 path")
}

fn run(program: &str, args: &[&str]) {
    let status = Command::new(program)
        .args(args)
        .status()
        .unwrap_or_else(|e| panic!("cannot run {program} (is it installed and on PATH?): {e}"));
    assert!(status.success(), "{program} {args:?} failed");
}

/// The 16 ANSI colours (as a dark terminal theme draws them), then the 256-colour cube.
fn color(color: vt100::Color, default: &str) -> String {
    const ANSI: [&str; 16] = [
        "#2e3440", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#d8dee9",
        "#7f848e", "#ef8891", "#b5e890", "#f0d197", "#8cc8ff", "#dca3f0", "#7fd4df", "#ffffff",
    ];
    match color {
        vt100::Color::Default => default.to_owned(),
        vt100::Color::Idx(i) if i < 16 => ANSI[i as usize].to_owned(),
        vt100::Color::Idx(i) if i >= 232 => {
            let v = 8 + (i - 232) * 10;
            format!("#{v:02x}{v:02x}{v:02x}")
        }
        vt100::Color::Idx(i) => {
            let i = i - 16;
            let level = |n: u8| if n == 0 { 0 } else { 55 + n * 40 };
            format!(
                "#{:02x}{:02x}{:02x}",
                level(i / 36),
                level((i / 6) % 6),
                level(i % 6)
            )
        }
        vt100::Color::Rgb(r, g, b) => format!("#{r:02x}{g:02x}{b:02x}"),
    }
}

fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}
