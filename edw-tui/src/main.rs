use edw_tui::{
    agent::{self, AgentEvent, ModelSource, Request},
    app::{Action, App, ChatLine},
    contract,
    edw::{self, EdwConfig},
    ui,
};
use futures::StreamExt;
use ratatui::crossterm::event::{Event, EventStream, KeyEventKind};
use tokio::sync::mpsc;

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
    let model = source.handle(&model_name)?;

    let (event_tx, mut events) = mpsc::unbounded_channel::<AgentEvent>();
    let (requests, request_rx) = mpsc::unbounded_channel::<Request>();
    let mut app = App::new(&model_name, config.data_dir.display().to_string());
    if let Some(warning) = edw::check_pin(&config.binary).warning() {
        app.chat.push(ChatLine::Info(warning));
    }
    let agent = agent::build_agent(model, config, event_tx.clone());
    tokio::spawn(agent::run(agent, request_rx, event_tx, source));

    let mut terminal = ratatui::init();
    let mut keys = EventStream::new();
    let result = async {
        loop {
            terminal.draw(|frame| ui::render(frame, &app))?;
            tokio::select! {
                Some(event) = keys.next() => {
                    if let Event::Key(key) = event? && key.kind == KeyEventKind::Press {
                        match app.on_key(key) {
                            Action::Send(request) => requests.send(request)?,
                            Action::Quit => return Ok(()),
                            Action::None => {}
                        }
                    }
                }
                Some(event) = events.recv() => app.on_agent(event),
            }
        }
    }
    .await;
    ratatui::restore();
    result
}
