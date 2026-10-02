use edw_tui::{
    agent::{self, AgentEvent, ModelSource, Request},
    app::{Action, App, ChatLine},
    contract,
    edw::{self, EdwConfig},
    interim::InterimConfig,
    skills::{self, tools::SkillSet},
    ui,
};
use futures::StreamExt;
use ratatui::crossterm::{
    event::{DisableBracketedPaste, EnableBracketedPaste, Event, EventStream, KeyEventKind},
    execute,
};
use tokio::sync::mpsc;

/// Puts `text` on the system clipboard with the platform's own tool.
fn copy_to_clipboard(text: &str) -> Result<(), String> {
    use std::{
        io::Write,
        process::{Command, Stdio},
    };
    let tools: [&[&str]; 3] = [
        &["pbcopy"],
        &["wl-copy"],
        &["xclip", "-selection", "clipboard"],
    ];
    for tool in tools {
        let Ok(mut child) = Command::new(tool[0])
            .args(&tool[1..])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
        else {
            continue;
        };
        if let Some(mut stdin) = child.stdin.take() {
            stdin
                .write_all(text.as_bytes())
                .map_err(|e| e.to_string())?;
        }
        return match child.wait() {
            Ok(status) if status.success() => Ok(()),
            _ => Err(format!("{} failed", tool[0])),
        };
    }
    Err("no clipboard tool found (pbcopy, wl-copy or xclip)".into())
}

/// Asks on the plain terminal (before the TUI starts) whether a skill may be used. Anything
/// but y, or a stdin that is not a terminal, is a no.
fn ask_consent(summary: &str) -> bool {
    use std::io::{BufRead, IsTerminal, Write};
    if !std::io::stdin().is_terminal() {
        eprintln!("{summary}\nNot allowed: stdin is not a terminal, so no one can agree to it.");
        return false;
    }
    println!("{summary}");
    print!("Allow this skill? Its plans are still reviewed before anything is sent. [y/N] ");
    let _ = std::io::stdout().flush();
    let mut line = String::new();
    let _ = std::io::stdin().lock().read_line(&mut line);
    matches!(line.trim(), "y" | "Y" | "yes")
}

const USAGE: &str = "usage: edw-tui [tools-dump]
  (no command)  start the chat TUI
  tools-dump    print the model-facing contract (preamble, tool schemas) as JSON";

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    match std::env::args().nth(1).as_deref() {
        None => {}
        Some("tools-dump") => {
            print!("{}", contract::dump_pretty());
            return Ok(());
        }
        Some("-h" | "--help") => {
            println!("{USAGE}");
            return Ok(());
        }
        Some(other) => anyhow::bail!("unknown command `{other}`\n{USAGE}"),
    }

    let model_name = std::env::var("EDW_TUI_MODEL").unwrap_or_else(|_| "qwen3:8b".into());
    let source = ModelSource {
        ollama_url: std::env::var("OLLAMA_HOST")
            .unwrap_or_else(|_| "http://127.0.0.1:11434".into()),
        // Only acts on an empty reply after a tool result (gemma4); a no-op for other models.
        nudge: std::env::var("EDW_TUI_NUDGE").map_or(true, |v| v != "0"),
    };
    let config = EdwConfig::from_env();
    let interim = InterimConfig::from_env(config.clone());
    let model = source.handle(&model_name)?;

    // Before the TUI takes the terminal: new or changed skills are agreed to here.
    let startup = if std::env::var("EDW_TUI_SKILLS").is_ok_and(|v| v == "off") {
        None
    } else {
        Some(skills::start(&skills::Paths::from_env(), ask_consent).await)
    };
    let (skill_set, skill_lines, skill_notes) = match startup {
        Some(s) => (s.set, skills::describe(&s.installed), s.notes),
        None => (
            std::sync::Arc::new(SkillSet::empty()),
            vec!["Skills are off (EDW_TUI_SKILLS=off).".into()],
            Vec::new(),
        ),
    };

    let (event_tx, mut events) = mpsc::unbounded_channel::<AgentEvent>();
    let (requests, request_rx) = mpsc::unbounded_channel::<Request>();
    let mut app = App::new(&model_name, config.data_dir.display().to_string());
    app.profile = interim.profile.get();
    if let Some(warning) = edw::check_pin(&config.binary).warning() {
        app.chat.push(ChatLine::Info(warning));
    }
    app.skills = skill_lines;
    app.chat.extend(skill_notes.into_iter().map(ChatLine::Info));
    let agent = agent::build_agent(model, config, interim.clone(), event_tx.clone(), skill_set);
    tokio::spawn(agent::run(agent, request_rx, event_tx, source, interim));

    let mut terminal = ratatui::init();
    // A paste arrives as one event instead of keystrokes, so its line breaks never press Enter.
    let _ = execute!(std::io::stdout(), EnableBracketedPaste);
    let mut keys = EventStream::new();
    let result = async {
        loop {
            terminal.draw(|frame| ui::render(frame, &app))?;
            tokio::select! {
                Some(event) = keys.next() => match event? {
                    Event::Key(key) if key.kind == KeyEventKind::Press => match app.on_key(key) {
                        Action::Send(request) => requests.send(request)?,
                        Action::Copy(text) => app.chat.push(match copy_to_clipboard(&text) {
                            Ok(()) => ChatLine::Info(format!("Copied {} characters.", text.chars().count())),
                            Err(error) => ChatLine::Error(format!("cannot copy: {error}")),
                        }),
                        Action::Quit => return Ok(()),
                        Action::None => {}
                    },
                    Event::Paste(text) => app.on_paste(&text),
                    _ => {}
                },
                Some(event) = events.recv() => app.on_agent(event),
            }
        }
    }
    .await;
    let _ = execute!(std::io::stdout(), DisableBracketedPaste);
    ratatui::restore();
    result
}
