use crate::Result;
use std::{env, path::PathBuf};

/// Creates and returns the cache directory pointed to by `MULLVAD_CACHE_DIR`, or the default
/// one if that variable is unset.
pub fn cache_dir() -> Result<PathBuf> {
    crate::create_and_return(get_cache_dir, None)
}

fn get_cache_dir() -> Result<PathBuf> {
    match env::var_os("MULLVAD_CACHE_DIR") {
        Some(path) => Ok(PathBuf::from(path)),
        None => get_default_cache_dir(),
    }
}

pub fn get_default_cache_dir() -> Result<PathBuf> {
    #[cfg(not(target_os = "android"))]
    {
        let dir;
        #[cfg(target_os = "linux")]
        {
            dir = Ok(PathBuf::from("/var/cache"))
        }
        #[cfg(any(target_os = "macos", windows))]
        {
            dir = dirs::cache_dir().ok_or_else(|| crate::Error::FindDirError)
        }
        dir.map(|dir| dir.join(crate::PRODUCT_NAME))
    }
    #[cfg(target_os = "android")]
    {
        Ok(std::path::Path::new(crate::APP_PATH).join("cache"))
    }
}
