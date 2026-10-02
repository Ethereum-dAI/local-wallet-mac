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
use std::collections::BTreeMap;

use tokio::sync::{mpsc, oneshot};

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

    // Skills are found now and agreed to in the TUI; the agent starts once they are settled.
    let discovery = (!std::env::var("EDW_TUI_SKILLS").is_ok_and(|v| v == "off"))
        .then(|| skills::discover(&skills::Paths::from_env()));

    let (event_tx, mut events) = mpsc::unbounded_channel::<AgentEvent>();
    let (requests, request_rx) = mpsc::unbounded_channel::<Request>();
    let mut app = App::new(&model_name, config.data_dir.display().to_string());
    app.profile = interim.profile.get();
    if let Some(warning) = edw::check_pin(&config.binary).warning() {
        app.chat.push(ChatLine::Info(warning));
    }
    app.ask_consents(
        discovery
            .as_ref()
            .map(|d| d.requests.clone())
            .unwrap_or_default(),
    );

    // Answers arrive from the TUI; finishing (Docker check, a first image pull) runs here so
    // the UI stays responsive, then the agent starts with the skills that are ready.
    let (answered, answers) = oneshot::channel::<BTreeMap<String, bool>>();
    let mut answered = Some(answered);
    {
        let events = event_tx.clone();
        tokio::spawn(async move {
            let answers = answers.await.unwrap_or_default();
            let (set, lines, notes) = match discovery {
                Some(discovery) => {
                    let startup = skills::finish(discovery, &answers).await;
                    (
                        startup.set,
                        skills::describe(&startup.installed),
                        startup.notes,
                    )
                }
                None => (
                    std::sync::Arc::new(SkillSet::empty()),
                    vec!["Skills are off (EDW_TUI_SKILLS=off).".into()],
                    Vec::new(),
                ),
            };
            let agent = agent::build_agent(model, config, interim.clone(), events.clone(), set);
            let _ = events.send(AgentEvent::SkillsReady { lines, notes });
            agent::run(agent, request_rx, events, source, interim).await;
        });
    }
    if app.consents.is_empty()
        && let Some(answered) = answered.take()
    {
        let _ = answered.send(BTreeMap::new());
    }

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
                        Action::SkillsAnswered(answers) => {
                            if let Some(answered) = answered.take() {
                                let _ = answered.send(answers);
                            }
                        }
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
