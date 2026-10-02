//! A stand-in model that plays back fixed replies and records the tools each request offered.

use std::{
    collections::VecDeque,
    sync::{Arc, Mutex},
};

use rig_agent::{
    completion::{CompletionError, CompletionModel, CompletionRequest, CompletionResponse, Usage},
    streaming::StreamingCompletionResponse,
};
use rig_core::message::{AssistantContent, ToolCall, ToolFunction};
use serde_json::Value;

#[derive(Clone)]
pub struct Recorder {
    pub replies: Arc<Mutex<VecDeque<AssistantContent>>>,
    pub offered: Arc<Mutex<Vec<Vec<String>>>>,
}

impl Recorder {
    pub fn new(replies: Vec<AssistantContent>) -> Self {
        Self {
            replies: Arc::new(Mutex::new(replies.into())),
            offered: Arc::default(),
        }
    }
}

pub fn call(name: &str, args: Value) -> AssistantContent {
    AssistantContent::ToolCall(ToolCall::from_wire(
        format!("rec-{name}"),
        ToolFunction::new(name.to_owned(), args),
    ))
}

impl CompletionModel for Recorder {
    async fn completion(
        &self,
        request: CompletionRequest,
    ) -> Result<CompletionResponse, CompletionError> {
        self.offered
            .lock()
            .unwrap()
            .push(request.tools.iter().map(|t| t.name.clone()).collect());
        let reply = self
            .replies
            .lock()
            .unwrap()
            .pop_front()
            .unwrap_or_else(|| AssistantContent::text("done"));
        Ok(CompletionResponse::new(
            vec![reply],
            Usage::new(),
            "recorder",
        ))
    }

    async fn stream(
        &self,
        _request: CompletionRequest,
    ) -> Result<StreamingCompletionResponse, CompletionError> {
        Err(CompletionError::ResponseError("no streaming".into()))
    }
}
