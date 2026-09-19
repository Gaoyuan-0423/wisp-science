use wisp_store::Store;

const PAGE_TURNS: usize = 20;

struct Replay {
    store: Store,
    model_seq: i64,
    event_seq: i64,
    question: usize,
}

impl Replay {
    async fn event(&mut self, event: serde_json::Value) {
        self.event_seq += 1;
        self.store
            .append_session_ui_event("f", self.event_seq, &event.to_string())
            .await
            .unwrap();
    }
    async fn turn(&mut self) {
        self.question += 1;
        let text = format!("question {}", self.question);
        self.model_seq += 1;
        self.store
            .append_message("f", self.model_seq, &wisp_llm::Message::user(&text))
            .await
            .unwrap();
        self.event(serde_json::json!({"kind":"User","frame_id":"f","text":text}))
            .await;
        self.event(
            serde_json::json!({"kind":"MessageBoundary","frame_id":"f","seq":self.model_seq}),
        )
        .await;
        self.model_seq += 1;
        self.store
            .append_message(
                "f",
                self.model_seq,
                &wisp_llm::Message::assistant(format!("answer {}", self.question)),
            )
            .await
            .unwrap();
        self.event(serde_json::json!({"kind":"Text","frame_id":"f","delta":format!("answer {}", self.question)}))
            .await;
        self.event(
            serde_json::json!({"kind":"MessageBoundary","frame_id":"f","seq":self.model_seq}),
        )
        .await;
    }
}

fn page_user_texts(page: &wisp_store::SessionTranscriptPage) -> Vec<String> {
    page.ui_events
        .iter()
        .filter_map(|json| serde_json::from_str::<serde_json::Value>(json).ok())
        .filter(|event| event["kind"] == "User")
        .filter_map(|event| event["text"].as_str().map(str::to_string))
        .collect()
}

#[tokio::test]
async fn compacted_history_keeps_visual_indices_and_reachable_questions() {
    let root =
        std::env::temp_dir().join(format!("wisp_compacted_history_{}", uuid::Uuid::new_v4()));
    let store = Store::open(&root.join("wisp.sqlite")).await.unwrap();
    store
        .create_project("p", "Project", &root.to_string_lossy())
        .await
        .unwrap();
    store
        .create_frame("f", "p", "OPERON", "model")
        .await
        .unwrap();
    store
        .append_message("f", 1, &wisp_llm::Message::system("system"))
        .await
        .unwrap();
    let mut replay = Replay {
        store: store.clone(),
        model_seq: 1,
        event_seq: 0,
        question: 0,
    };
    for _ in 0..50 {
        replay.turn().await;
    }
    // Compaction keeps system + checkpoint + last 10 turns, renumbered from 1.
    let all = store.load_messages_with_seq("f").await.unwrap();
    let mut compacted = vec![wisp_llm::Message::system("system")];
    compacted.push(wisp_llm::Message::user("[compacted; summary checkpoint]"));
    compacted.extend(all.iter().rev().take(20).rev().map(|(_, m)| m.clone()));
    store.replace_messages("f", &compacted).await.unwrap();
    replay.model_seq = store.max_message_seq("f").await.unwrap();
    for _ in 0..30 {
        replay.turn().await;
    }

    let current = store.load_session_user_messages("f").await.unwrap();
    assert_eq!(current.len(), 40, "checkpoints are not questions");
    let outline = store.load_session_outline("f").await.unwrap();
    assert_eq!(outline.len(), 80);
    for (index, entry) in outline.iter().enumerate() {
        assert_eq!(entry.user_index, index);
        assert_eq!(entry.text, format!("question {}", index + 1));
        assert_eq!(
            entry.seq, None,
            "event boundaries must not become model cursors"
        );
    }
    let mut cursor = None;
    let mut pages = Vec::new();
    loop {
        let page = store
            .load_session_transcript_page("f", cursor, PAGE_TURNS)
            .await
            .unwrap();
        let texts = page_user_texts(&page);
        assert_eq!(
            page.event_message_prefix_len,
            Some(0),
            "compacted model rows must not prefix event replay"
        );
        for (index, text) in texts.iter().enumerate() {
            assert_eq!(text, &outline[page.user_offset + index].text);
        }
        cursor = page.next_before_seq;
        pages.push((page.user_offset, texts));
        if cursor.is_none() {
            break;
        }
    }
    assert_eq!(
        pages.iter().map(|(offset, _)| *offset).collect::<Vec<_>>(),
        [60, 1, 0]
    );
    let all = pages
        .iter()
        .rev()
        .flat_map(|(_, texts)| texts.iter().cloned())
        .collect::<Vec<_>>();
    assert_eq!(
        all,
        outline
            .iter()
            .map(|item| item.text.clone())
            .collect::<Vec<_>>()
    );
    for target in [0, 5, 45, 60, 79] {
        let mut cursor = None;
        loop {
            let page = store
                .load_session_transcript_page("f", cursor, PAGE_TURNS)
                .await
                .unwrap();
            let texts = page_user_texts(&page);
            if target >= page.user_offset && target < page.user_offset + texts.len() {
                assert_eq!(texts[target - page.user_offset], outline[target].text);
                break;
            }
            cursor = Some(
                page.next_before_seq
                    .expect("every historical question remains reachable"),
            );
        }
    }

    // A second rewrite with no subsequent turn is also reachable; no new
    // boundary is required to recover the old questions.
    store
        .replace_messages(
            "f",
            &[
                wisp_llm::Message::system("system"),
                wisp_llm::Message::user("[context summary checkpoint] summary"),
                wisp_llm::Message::user("question 80"),
                wisp_llm::Message::assistant("answer 80"),
            ],
        )
        .await
        .unwrap();
    let page = store
        .load_session_transcript_page("f", None, PAGE_TURNS)
        .await
        .unwrap();
    assert_eq!(page.user_offset, 0);
    assert_eq!(page_user_texts(&page), all);
    assert_eq!(store.load_session_outline("f").await.unwrap().len(), 80);
}

#[tokio::test]
async fn legacy_outline_filters_both_checkpoint_formats() {
    let root = std::env::temp_dir().join(format!("wisp_legacy_outline_{}", uuid::Uuid::new_v4()));
    let store = Store::open(&root.join("wisp.sqlite")).await.unwrap();
    store.create_project("p", "Project", "").await.unwrap();
    store.create_frame("f", "p", "OPERON", "m").await.unwrap();
    store
        .replace_messages(
            "f",
            &[
                wisp_llm::Message::user("[compacted; old summary]"),
                wisp_llm::Message::user("[context summary checkpoint] summary"),
                wisp_llm::Message::user("real question"),
            ],
        )
        .await
        .unwrap();
    let outline = store.load_session_outline("f").await.unwrap();
    assert_eq!(outline.len(), 1);
    assert_eq!(outline[0].text, "real question");
    assert_eq!(outline[0].seq, Some(3));
    assert_eq!(outline[0].user_index, 0);
    let page = store
        .load_session_transcript_page("f", None, 1)
        .await
        .unwrap();
    assert_eq!(page.user_offset, 0);
}
