use std::fs::{self, OpenOptions};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Manager};
use uuid::Uuid;

#[derive(Default, Deserialize, Serialize)]
struct StoragePreference {
    data_dir: Option<PathBuf>,
}

#[derive(Serialize)]
pub struct StorageSettings {
    default_data_dir: String,
    saved_data_dir: String,
    startup_warning: Option<String>,
}

fn default_data_dir(app: &AppHandle) -> Result<PathBuf, String> {
    app.path()
        .app_local_data_dir()
        .map(|path| path.join("data"))
        .map_err(|error| format!("无法获取默认数据目录：{error}"))
}

fn preference_path(app: &AppHandle) -> Result<PathBuf, String> {
    app.path()
        .app_local_data_dir()
        .map(|path| path.join("desktop-storage.json"))
        .map_err(|error| format!("无法获取桌面配置目录：{error}"))
}

fn read_preference(app: &AppHandle) -> Result<StoragePreference, String> {
    let path = preference_path(app)?;
    read_preference_from(&path)
}

fn read_preference_from(path: &Path) -> Result<StoragePreference, String> {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(StoragePreference::default());
        }
        Err(error) => return Err(format!("无法读取数据目录配置：{error}")),
    };
    serde_json::from_slice(&bytes).map_err(|error| format!("数据目录配置格式无效：{error}"))
}

fn write_preference(app: &AppHandle, preference: &StoragePreference) -> Result<(), String> {
    let path = preference_path(app)?;
    write_preference_to(&path, preference)
}

fn write_preference_to(path: &Path, preference: &StoragePreference) -> Result<(), String> {
    let parent = path.parent().ok_or("数据目录配置路径无效")?;
    fs::create_dir_all(parent).map_err(|error| format!("无法创建配置目录：{error}"))?;
    let bytes = serde_json::to_vec_pretty(preference)
        .map_err(|error| format!("无法生成数据目录配置：{error}"))?;
    fs::write(&path, bytes).map_err(|error| format!("无法保存数据目录配置：{error}"))
}

fn validate_directory(path: &Path) -> Result<PathBuf, String> {
    if !path.is_absolute() {
        return Err("请选择绝对路径的数据目录。".to_owned());
    }
    let resolved =
        dunce::canonicalize(path).map_err(|error| format!("目录不存在或无法访问：{error}"))?;
    if !resolved.is_dir() {
        return Err("所选路径不是文件夹。".to_owned());
    }
    let probe = resolved.join(format!(".medvision-write-test-{}", Uuid::new_v4()));
    let file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&probe)
        .map_err(|error| format!("目录不可写：{error}"))?;
    drop(file);
    fs::remove_file(&probe).map_err(|error| format!("无法清理目录写入检查文件：{error}"))?;
    Ok(resolved)
}

pub fn resolve_for_startup(app: &AppHandle) -> Result<(PathBuf, Option<String>), String> {
    let default = default_data_dir(app)?;
    match read_preference(app) {
        Ok(StoragePreference {
            data_dir: Some(saved),
        }) => match validate_directory(&saved) {
            Ok(path) => Ok((path, None)),
            Err(error) => Ok((
                default,
                Some(format!(
                    "自定义数据目录不可用，已改用默认目录；原数据未移动。{error}"
                )),
            )),
        },
        Ok(_) => Ok((default, None)),
        Err(error) => Ok((
            default,
            Some(format!(
                "读取数据目录配置失败，已改用默认目录；原数据未移动。{error}"
            )),
        )),
    }
}

pub fn settings(
    app: &AppHandle,
    startup_warning: Option<String>,
) -> Result<StorageSettings, String> {
    let default = default_data_dir(app)?;
    let (saved, read_warning) = match read_preference(app) {
        Ok(preference) => (preference.data_dir.unwrap_or_else(|| default.clone()), None),
        Err(error) => (default.clone(), Some(error)),
    };
    Ok(StorageSettings {
        default_data_dir: default.to_string_lossy().into_owned(),
        saved_data_dir: saved.to_string_lossy().into_owned(),
        startup_warning: startup_warning.or(read_warning),
    })
}

pub fn select_directory(app: &AppHandle, directory: String) -> Result<String, String> {
    let path = validate_directory(Path::new(directory.trim()))?;
    write_preference(
        app,
        &StoragePreference {
            data_dir: Some(path.clone()),
        },
    )?;
    Ok(path.to_string_lossy().into_owned())
}

pub fn reset_to_default(app: &AppHandle) -> Result<String, String> {
    write_preference(app, &StoragePreference::default())?;
    Ok(default_data_dir(app)?.to_string_lossy().into_owned())
}

#[cfg(test)]
mod tests {
    use super::{read_preference_from, validate_directory, write_preference_to, StoragePreference};
    use std::fs;
    use uuid::Uuid;

    #[test]
    fn selected_directory_must_exist_and_be_writable() {
        let dir = std::env::temp_dir().join(format!("medvision-storage-test-{}", Uuid::new_v4()));
        fs::create_dir(&dir).unwrap();
        let resolved = validate_directory(&dir).unwrap();
        assert_eq!(resolved, dunce::canonicalize(&dir).unwrap());
        #[cfg(windows)]
        assert!(!resolved.to_string_lossy().starts_with(r"\\?\"));
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 0);
        assert!(validate_directory(&dir.join("missing")).is_err());
        fs::remove_dir(&dir).unwrap();
    }

    #[test]
    fn directory_preference_persists_and_can_reset() {
        let dir = std::env::temp_dir().join(format!("medvision-storage-test-{}", Uuid::new_v4()));
        fs::create_dir(&dir).unwrap();
        let config = dir.join("desktop-storage.json");
        let selected = dir.join("patient-data");
        write_preference_to(
            &config,
            &StoragePreference {
                data_dir: Some(selected.clone()),
            },
        )
        .unwrap();
        assert_eq!(
            read_preference_from(&config).unwrap().data_dir,
            Some(selected)
        );
        write_preference_to(&config, &StoragePreference::default()).unwrap();
        assert_eq!(read_preference_from(&config).unwrap().data_dir, None);
        fs::remove_file(config).unwrap();
        fs::remove_dir(dir).unwrap();
    }
}
