//! App-owned conversion state survives leaving Workflow Studio and its dialog.
use crate::app_support::compose_icon;
use crate::bindings::{invoke_checked, listen_current_window};
use crate::dto::{
    ProjectInfo, SkillPortfolioDraft, SkillPortfolioRequest, WorkflowConversionProgress,
    WorkflowConversionStage,
};
use crate::i18n::{t, tf, Locale};
use leptos::*;
use wasm_bindgen::{closure::Closure, JsCast, JsValue};

#[derive(Clone, Copy)]
pub(crate) struct ConversionState {
    pub open: RwSignal<bool>,
    pub open_requested: RwSignal<bool>,
    pub request: RwSignal<String>,
    pub model_id: RwSignal<String>,
    pub sources: RwSignal<Vec<String>>,
    pub auto_sources: RwSignal<bool>,
    pub source_search: RwSignal<String>,
    pub legacy_template: RwSignal<Option<String>>,
    pub legacy_workflow: RwSignal<Option<String>>,
    pub draft: RwSignal<Option<SkillPortfolioDraft>>,
    pub loading: RwSignal<bool>,
    pub error: RwSignal<Option<String>>,
    pub id: RwSignal<Option<String>>,
    pub project: RwSignal<Option<(String, String)>>,
    current_project: RwSignal<Option<ProjectInfo>>,
    stage: RwSignal<WorkflowConversionStage>,
    started_at: RwSignal<f64>,
    elapsed: RwSignal<u64>,
}

impl ConversionState {
    pub fn new(current_project: RwSignal<Option<ProjectInfo>>) -> Self {
        let state = Self {
            open: create_rw_signal(false),
            open_requested: create_rw_signal(false),
            request: create_rw_signal(String::new()),
            model_id: create_rw_signal(String::new()),
            sources: create_rw_signal(vec![]),
            auto_sources: create_rw_signal(true),
            source_search: create_rw_signal(String::new()),
            legacy_template: create_rw_signal(None),
            legacy_workflow: create_rw_signal(None),
            draft: create_rw_signal(None),
            loading: create_rw_signal(false),
            error: create_rw_signal(None),
            id: create_rw_signal(None),
            project: create_rw_signal(None),
            current_project,
            stage: create_rw_signal(WorkflowConversionStage::Preparing),
            started_at: create_rw_signal(0.0),
            elapsed: create_rw_signal(0),
        };
        let timer = set_interval_with_handle(
            move || {
                if state.loading.get_untracked() {
                    state.elapsed.set(
                        ((js_sys::Date::now() - state.started_at.get_untracked()) / 1000.0) as u64,
                    );
                }
            },
            std::time::Duration::from_secs(1),
        )
        .ok();
        on_cleanup(move || {
            if let Some(timer) = timer {
                timer.clear();
            }
        });
        create_effect(move |_| {
            if !state.belongs_to_current_project() {
                state.open.set(false);
            }
        });
        // Input edits invalidate completed drafts, but hiding/remounting the
        // dialog does not. Inputs are disabled while the captured request runs.
        create_effect(move |_| {
            let _inputs = (
                state.request.get(),
                state.model_id.get(),
                state.sources.get(),
                state.auto_sources.get(),
                state.legacy_template.get(),
                state.legacy_workflow.get(),
            );
            if !state.loading.get_untracked() {
                state.draft.set(None);
                state.error.set(None);
                state.id.set(None);
                state.project.set(None);
            }
        });
        state
    }

    pub fn belongs_to_current_project(self) -> bool {
        let owner = self.project.get();
        let current = self.current_project.get();
        owner.is_none_or(|(id, _)| current.is_some_and(|project| project.id == id))
    }

    pub fn start(self, request: SkillPortfolioRequest) {
        if self.loading.get_untracked() {
            return;
        }
        let Some(project) = self.current_project.get_untracked() else {
            return;
        };
        let id = format!(
            "conversion-{}-{}",
            js_sys::Date::now(),
            js_sys::Math::random()
        );
        self.id.set(Some(id.clone()));
        self.project.set(Some((project.id.clone(), project.name)));
        self.draft.set(None);
        self.error.set(None);
        self.stage.set(WorkflowConversionStage::Preparing);
        self.started_at.set(js_sys::Date::now());
        self.elapsed.set(0);
        self.loading.set(true);
        // Only root-owned signals are captured. The initiating studio may unmount.
        spawn_local(async move {
            let event_id = id.clone();
            let callback = Closure::<dyn Fn(JsValue)>::new(move |payload| {
                if let Ok(progress) =
                    serde_wasm_bindgen::from_value::<WorkflowConversionProgress>(payload)
                {
                    if progress.conversion_id == event_id && self.loading.get_untracked() {
                        self.stage.set(progress.stage);
                    }
                }
            });
            // Subscribe before invoking so even immediate host stages are visible.
            let unlisten = listen_current_window(
                "workflow-conversion-progress",
                callback.as_ref().unchecked_ref(),
            )
            .await;
            let args = serde_json::json!({"request": request, "conversionId": id, "expectedProjectId": project.id});
            let result = invoke_checked(
                "plan_skill_portfolio",
                serde_wasm_bindgen::to_value(&args).unwrap(),
            )
            .await;
            if let Some(unlisten) = unlisten.dyn_ref::<js_sys::Function>() {
                let _ = unlisten.call0(&JsValue::UNDEFINED);
            }
            drop(callback);
            match result {
                Ok(value) => match serde_wasm_bindgen::from_value(value) {
                    Ok(draft) => self.draft.set(Some(draft)),
                    Err(error) => self.error.set(Some(error.to_string())),
                },
                Err(error) => self.error.set(Some(
                    error
                        .as_string()
                        .or_else(|| {
                            js_sys::Reflect::get(&error, &JsValue::from_str("message"))
                                .ok()
                                .and_then(|value| value.as_string())
                        })
                        .unwrap_or_else(|| "Workflow conversion failed".into()),
                )),
            }
            self.elapsed
                .set(((js_sys::Date::now() - self.started_at.get_untracked()) / 1000.0) as u64);
            self.loading.set(false);
        });
    }

    fn label(self, locale: Locale) -> String {
        let key = if self.error.get().is_some() {
            "failed"
        } else if self.draft.get().is_some() {
            "ready"
        } else {
            match self.stage.get() {
                WorkflowConversionStage::Preparing => "preparing",
                WorkflowConversionStage::SelectingSources => "selecting",
                WorkflowConversionStage::ReadingSources => "reading",
                WorkflowConversionStage::Generating => "generating",
                WorkflowConversionStage::Validating => "validating",
                WorkflowConversionStage::Repairing => "repairing",
                WorkflowConversionStage::Saving => "saving",
            }
        };
        t(locale, &format!("workflow_studio.conversion.{key}"))
    }
}

#[component]
pub(crate) fn ConversionProgress(
    state: ConversionState,
    locale: RwSignal<Locale>,
) -> impl IntoView {
    view! {
        <section class="conversion-progress" data-testid="conversion-progress" aria-busy=move || state.loading.get().to_string()>
            <strong role="status" aria-live="polite">{move || state.label(locale.get())}</strong>
            <span class="conversion-elapsed">{move || tf(locale.get(), "workflow_studio.conversion.elapsed", &[("time", &format!("{}:{:02}", state.elapsed.get() / 60, state.elapsed.get() % 60))])}</span>
            <div class="conversion-activity" class:running=move || state.loading.get() aria-hidden="true"><span></span></div>
            <p>{move || t(locale.get(), "workflow_studio.conversion.background_hint")}</p>
        </section>
    }
}

#[component]
pub(crate) fn ConversionNotice(
    state: ConversionState,
    locale: RwSignal<Locale>,
    visible: Signal<bool>,
    on_open: Callback<()>,
) -> impl IntoView {
    view! {
        <Show when=move || state.id.get().is_some() && visible.get()>
            <aside class="conversion-notice" data-testid="conversion-notice">
                <span class="conversion-notice-icon">{compose_icon("branch")}</span>
                <div>
                    <strong role="status" aria-live="polite">{move || state.label(locale.get())}</strong>
                    <small>{move || state.project.get().map(|(_, name)| name).unwrap_or_default()}</small>
                    <span class="conversion-elapsed">{move || tf(locale.get(), "workflow_studio.conversion.elapsed", &[("time", &format!("{}:{:02}", state.elapsed.get() / 60, state.elapsed.get() % 60))])}</span>
                </div>
                <button type="button" data-testid="conversion-open" on:click=move |_| on_open.call(())>
                    {move || t(locale.get(), if state.loading.get() { "workflow_studio.conversion.view_progress" } else { "workflow_studio.conversion.view_result" })}
                </button>
            </aside>
        </Show>
    }
}
