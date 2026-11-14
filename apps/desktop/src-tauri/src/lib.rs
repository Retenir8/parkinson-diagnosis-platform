use std::sync::Mutex;
use tauri::Manager;
use tauri_plugin_shell::process::{CommandChild, CommandEvent};
use tauri_plugin_shell::ShellExt;

mod storage;

struct BackendState {
    api_base: String,
    token: String,
    child: Mutex<Option<CommandChild>>,
    startup_warning: Option<String>,
}

#[tauri::command]
fn desktop_connection(state: tauri::State<'_, BackendState>) -> (String, String) {
    (state.api_base.clone(), state.token.clone())
}

#[tauri::command]
fn desktop_storage_settings(
    app: tauri::AppHandle,
    state: tauri::State<'_, BackendState>,
) -> Result<storage::StorageSettings, String> {
    if cfg!(debug_assertions) {
        return Err("开发模式的数据目录由 Python 服务配置。".to_owned());
    }
    storage::settings(&app, state.startup_warning.clone())
}

#[tauri::command]
fn set_desktop_data_directory(app: tauri::AppHandle, directory: String) -> Result<String, String> {
    if cfg!(debug_assertions) {
        return Err("开发模式的数据目录由 Python 服务配置。".to_owned());
    }
    storage::select_directory(&app, directory)
}

#[tauri::command]
fn reset_desktop_data_directory(app: tauri::AppHandle) -> Result<String, String> {
    if cfg!(debug_assertions) {
        return Err("开发模式的数据目录由 Python 服务配置。".to_owned());
    }
    storage::reset_to_default(&app)
}

fn stop_backend(child: CommandChild) {
    // PyInstaller's one-file bootloader launches a second process. Killing
    // only the bootloader leaves the API running after the desktop window exits.
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;

        let stopped_tree = std::process::Command::new("taskkill")
            .args(["/PID", &child.pid().to_string(), "/T", "/F"])
            .creation_flags(0x08000000) // CREATE_NO_WINDOW
            .status()
            .is_ok_and(|status| status.success());
        if stopped_tree {
            return;
        }
    }
    let _ = child.kill();
}

fn start_backend(app: &mut tauri::App) -> Result<BackendState, Box<dyn std::error::Error>> {
    #[cfg(debug_assertions)]
    {
        // The development script already runs uvicorn with hot reload.
        let _ = app;
        return Ok(BackendState {
            api_base: "http://127.0.0.1:8000/api/v1".to_owned(),
            token: "development".to_owned(),
            child: Mutex::new(None),
            startup_warning: None,
        });
    }

    #[cfg(not(debug_assertions))]
    {
        use std::io::Write;
        use std::net::TcpListener;
        use uuid::Uuid;

        // A random loopback port avoids connecting to an unrelated service on
        // the old fixed port. The token also prevents other local clients from
        // reading patient records from the bundled API.
        let listener = TcpListener::bind("127.0.0.1:0")?;
        let port = listener.local_addr()?.port();
        drop(listener);

        let (data_dir, startup_warning) =
            storage::resolve_for_startup(app.handle()).map_err(std::io::Error::other)?;
        std::fs::create_dir_all(&data_dir)?;
        let log_dir = data_dir.join("logs");
        std::fs::create_dir_all(&log_dir)?;
        let log_path = log_dir.join("sidecar.log");
        let token = Uuid::new_v4().simple().to_string();
        let arguments = vec![
            "--port".to_owned(),
            port.to_string(),
            "--data-dir".to_owned(),
            data_dir.to_string_lossy().into_owned(),
        ];
        let (mut events, child) = app
            .shell()
            .sidecar("medvision-server")?
            .args(arguments)
            .env("MEDVISION_DESKTOP_TOKEN", &token)
            .spawn()?;
        tauri::async_runtime::spawn(async move {
            if let Ok(mut log) = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(log_path)
            {
                while let Some(event) = events.recv().await {
                    match event {
                        CommandEvent::Stdout(bytes) | CommandEvent::Stderr(bytes) => {
                            let _ = log.write_all(&bytes);
                            let _ = log.write_all(b"\n");
                        }
                        CommandEvent::Error(message) => {
                            let _ = writeln!(log, "sidecar error: {message}");
                        }
                        CommandEvent::Terminated(status) => {
                            let _ = writeln!(log, "sidecar exited: {:?}", status.code);
                        }
                        _ => {}
                    }
                }
            }
        });
        Ok(BackendState {
            api_base: format!("http://127.0.0.1:{port}/api/v1"),
            token,
            child: Mutex::new(Some(child)),
            startup_warning,
        })
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![
            desktop_connection,
            desktop_storage_settings,
            set_desktop_data_directory,
            reset_desktop_data_directory
        ])
        .setup(|app| {
            let state = start_backend(app)?;
            app.manage(state);
            Ok(())
        })
        .on_window_event(|window, event| {
            if window.label() == "main" && matches!(event, tauri::WindowEvent::Destroyed) {
                let state = window.state::<BackendState>();
                if let Ok(mut child) = state.child.lock() {
                    if let Some(child) = child.take() {
                        stop_backend(child);
                    }
                };
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running the desktop application");
}
