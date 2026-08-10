#ifndef KEY_MANAGER_H
#define KEY_MANAGER_H

#include <string>
#include <stdexcept> // For std::runtime_error

// Structure to hold results or errors from key operations
struct KeyOperationResult {
    bool success;
    std::string error_message;
    std::string decrypted_pem; // Only used by decryption function
};

/**
 * @brief Generates an RSA key pair and writes the PEM-encoded keys to file descriptors.
 *
 * IMPORTANT: The caller (eTS/NAPI) is responsible for opening the file descriptors
 *            before calling this function and closing them *after* the asynchronous
 *            operation completes. This function uses fdopen and BIO_NOCLOSE, assuming
 *            the fds are valid and managed externally. Direct fd passing can be risky.
 *
 * @param algorithm The desired algorithm (currently ignored, defaults to RSA 2048).
 * @param password The password to encrypt the private key (empty for no encryption).
 * @param private_key_fd The file descriptor for the private key file.
 * @param public_key_fd The file descriptor for the public key file.
 * @param bits The key size in bits (e.g., 2048).
 * @return KeyOperationResult indicating success or failure.
 */
KeyOperationResult generate_key_pair_to_fd(
    const std::string& algorithm,
    const std::string& password,
    int private_key_fd,
    int public_key_fd,
    int bits = 2048);

/**
 * @brief Reads an encrypted private key from a file descriptor, decrypts it, and returns the PEM.
 *
 * IMPORTANT: The caller (eTS/NAPI) is responsible for opening the file descriptor
 *            before calling this function and closing it *after* the asynchronous
 *            operation completes. This function uses fdopen and BIO_NOCLOSE.
 *
 * @param private_key_fd The file descriptor for the encrypted private key file.
 * @param password The password to decrypt the private key.
 * @return KeyOperationResult containing the decrypted PEM on success, or an error message on failure.
 */
KeyOperationResult decrypt_private_key_from_fd(
    int private_key_fd,
    const std::string& password);


#endif // KEY_MANAGER_H 