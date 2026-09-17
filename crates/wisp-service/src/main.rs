use std::collections::HashSet;
use std::io::{BufRead, Read, Write};
use std::path::PathBuf;

use anyhow::{bail, Context, Result};
use wisp_dto::project_browser::{
    ActivitySource, Command, ErrorCode, Reply, Request, Response, SCHEMA,
};
use wisp_store::Store;

const MAX_REQUEST_BYTES: u64 = 64 * 1024;

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("{error:#}");
        std::process::exit(1);
    }
}

async fn run() -> Result<()> {
    let mut args = std::env::args_os().skip(1);
    let flag = args.next();
    let database = args.next();
    if flag.as_deref() != Some(std::ffi::OsStr::new("--database"))
        || database.is_none()
        || args.next().is_some()
    {
        bail!("Usage: wisp-service --database <existing-wisp.sqlite>");
    }
    let database = PathBuf::from(database.unwrap());
    let store = Store::open_read_only(&database)
        .await
        .with_context(|| format!("Cannot open database read-only: {}", database.display()))?;
    let stdin = std::io::stdin();
    let mut input = stdin.lock();
    let stdout = std::io::stdout();
    let mut output = stdout.lock();
    loop {
        let mut line = Vec::new();
        let count = (&mut input)
            .take(MAX_REQUEST_BYTES + 1)
            .read_until(b'\n', &mut line)?;
        if count == 0 {
            break;
        }
        if count as u64 > MAX_REQUEST_BYTES {
            bail!("Request exceeds 64 KiB");
        }
        let response = handle_request(&store, &line).await;
        serde_json::to_writer(&mut output, &response)?;
        output.write_all(b"\n")?;
        output.flush()?;
    }
    Ok(())
}

async fn handle_request(store: &Store, line: &[u8]) -> Response {
    let request = match serde_json::from_slice::<Request>(line) {
        Ok(request) => request,
        Err(error) => {
            return Response {
                schema: SCHEMA.into(),
                id: None,
                reply: Reply::Error {
                    code: ErrorCode::InvalidRequest,
                    message: error.to_string(),
                },
            };
        }
    };
    let reply = if request.schema != SCHEMA {
        Reply::Error {
            code: ErrorCode::UnsupportedSchema,
            message: format!("Expected {SCHEMA}"),
        }
    } else if request.id.trim().is_empty() {
        Reply::Error {
            code: ErrorCode::InvalidRequest,
            message: "Request id must not be empty".into(),
        }
    } else {
        match request.command {
            Command::Capabilities => Reply::Capabilities {
                commands: vec!["list_projects".into(), "capabilities".into()],
                read_only: true,
            },
            Command::ListProjects => {
                let idle = HashSet::new();
                match wisp_app::projects::list_projects(store, &idle, &idle).await {
                    Ok(projects) => Reply::Projects {
                        projects,
                        activity_source: ActivitySource::PersistedOnly,
                    },
                    Err(error) => Reply::Error {
                        code: ErrorCode::QueryFailed,
                        message: error.to_string(),
                    },
                }
            }
        }
    };
    Response {
        schema: SCHEMA.into(),
        id: Some(request.id),
        reply,
    }
}
