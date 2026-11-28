use sha2::{Digest, Sha256};
use std::{
    ffi::{CStr, OsStr, c_char},
    fs::File,
    io::{self, ErrorKind, Read},
    os::unix::ffi::OsStrExt,
    path::Path,
};

fn digest(mut reader: impl Read) -> io::Result<[u8; 32]> {
    let mut bytes = vec![0u8; 256 * 1024];
    let mut digest = Sha256::new();
    loop {
        match reader.read(&mut bytes) {
            Ok(0) => return Ok(digest.finalize().into()),
            Ok(n) => digest.update(&bytes[..n]),
            Err(error) if error.kind() == ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
}

fn digest_file(path: &Path) -> io::Result<[u8; 32]> {
    let file = File::open(path)?;
    if !file.metadata()?.is_file() {
        return Err(io::Error::new(
            ErrorKind::InvalidInput,
            "not a regular file",
        ));
    }
    digest(file)
}

/// Hashes a file without retaining a pointer or mutating the file.
///
/// # Safety
/// `path` is a readable NUL-terminated buffer and `output` is a disjoint
/// writable buffer of exactly 32 or more bytes. Both must stay valid until
/// return. A nonzero result leaves the output unchanged.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn animewitcher_download_sha256_v1(
    path: *const c_char,
    output: *mut u8,
) -> i32 {
    if path.is_null() || output.is_null() {
        return 1;
    }
    let result = std::panic::catch_unwind(|| {
        let path = unsafe { CStr::from_ptr(path) };
        digest_file(Path::new(OsStr::from_bytes(path.to_bytes())))
    });
    if let Ok(Ok(value)) = result {
        unsafe { std::ptr::copy_nonoverlapping(value.as_ptr(), output, 32) };
        0
    } else {
        1
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn published_sha256_vectors() {
        for (data, expected) in [
            (
                &b""[..],
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            ),
            (
                &b"abc"[..],
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            ),
        ] {
            let hash: String = digest(data)
                .unwrap()
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect();
            assert_eq!(hash, expected);
        }
    }

    #[test]
    fn unavailable_source_does_not_expose_partial_output() {
        let input = c"/dev/null";
        let mut output = [0x42; 32];
        let status =
            unsafe { animewitcher_download_sha256_v1(input.as_ptr(), output.as_mut_ptr()) };
        assert_ne!(status, 0);
        assert_eq!(output, [0x42; 32]);
    }
}
