#include "key_manager.h"
#include <openssl/rsa.h>
#include <openssl/pem.h>
#include <openssl/bio.h>
#include <openssl/evp.h>
#include <openssl/err.h>
#include <openssl/bn.h> 
#include <openssl/ec.h>      // Needed for EC key operations
//#include <openssl/encoder.h> // Not strictly needed for this manual approach but good practice
#include <cstdio>            // For FILE*, fdopen, fflush, fputs
#include <memory>            // For std::unique_ptr
#include <vector>            // For byte buffers and password buffer
#include <string>
#include <stdexcept>
#include <string.h>          // For strncpy, strlen
#include <arpa/inet.h>       // For htonl (ensure availability on your platform)

// --- OpenSSL RAII Wrappers --- (Use smart pointers for resource management)
struct BIOFree { void operator()(BIO* bio) { if (bio) BIO_free_all(bio); } }; // Check for null
struct RSAFree { void operator()(RSA* rsa) { if (rsa) RSA_free(rsa); } };
struct EVPKeyFree { void operator()(EVP_PKEY* pkey) { if (pkey) EVP_PKEY_free(pkey); } };
struct BIGNUMFree { void operator()(BIGNUM* bn) { if (bn) BN_free(bn); } };
struct FILEClose { void operator()(FILE* fp) { if (fp) fclose(fp); } }; // To close FILE* from fdopen IF NEEDED (Not used here due to BIO_NOCLOSE)
struct EVPKeyCtxFree { void operator()(EVP_PKEY_CTX* ctx) { if (ctx) EVP_PKEY_CTX_free(ctx); } };

using BIOPtr = std::unique_ptr<BIO, BIOFree>;
using RSAPtr = std::unique_ptr<RSA, RSAFree>;
using EVPKeyPtr = std::unique_ptr<EVP_PKEY, EVPKeyFree>;
using BIGNUMPtr = std::unique_ptr<BIGNUM, BIGNUMFree>;
using EVPKeyCtxPtr = std::unique_ptr<EVP_PKEY_CTX, EVPKeyCtxFree>;
// using FILEPtr = std::unique_ptr<FILE, FILEClose>; // Use carefully, NAPI uses BIO_NOCLOSE

// --- Helper Function to get OpenSSL Error String ---
std::string get_openssl_error() {
    char err_buf[256];
    ERR_error_string_n(ERR_get_error(), err_buf, sizeof(err_buf));
    // Consider retrieving multiple errors if needed using ERR_get_error() in a loop
    return std::string(err_buf);
}

// --- Helper Functions for OpenSSH Public Key Format Serialization ---

// Helper to serialize data with a 32-bit big-endian length prefix
void serialize_ssh_string(std::vector<unsigned char>& buf, const unsigned char* data, size_t len) {
    uint32_t net_len = htonl(static_cast<uint32_t>(len)); // Network byte order (big-endian)
    const unsigned char* len_bytes = reinterpret_cast<const unsigned char*>(&net_len);
    buf.insert(buf.end(), len_bytes, len_bytes + sizeof(uint32_t));
    if (data && len > 0) {
        buf.insert(buf.end(), data, data + len);
    }
}

// Overload for std::string
void serialize_ssh_string(std::vector<unsigned char>& buf, const std::string& str) {
    serialize_ssh_string(buf, reinterpret_cast<const unsigned char*>(str.data()), str.length());
}

// Helper to serialize a BIGNUM as an mpint (length prefixed, big-endian, handle leading zero for positive)
void serialize_ssh_mpint(std::vector<unsigned char>& buf, const BIGNUM* bn) {
    if (!bn) {
         throw std::runtime_error("Cannot serialize null BIGNUM as mpint.");
    }
    int len = BN_num_bytes(bn);
    if (len < 0) { // Should not happen for valid BIGNUM
         throw std::runtime_error("BN_num_bytes returned negative length.");
    }
    if (len == 0) { // Handle zero BIGNUM (e.g., BN_zero()) - SSH format uses 4 zero bytes for length
        uint32_t net_len = htonl(0);
        const unsigned char* len_bytes = reinterpret_cast<const unsigned char*>(&net_len);
        buf.insert(buf.end(), len_bytes, len_bytes + sizeof(uint32_t));
        return;
    }

    std::vector<unsigned char> bn_buf(len);
    if (BN_bn2bin(bn, bn_buf.data()) != len) {
        throw std::runtime_error("BN_bn2bin failed: " + get_openssl_error());
    }

    // SSH mpint format requires a leading 0x00 if the MSB is 1 and the number is positive.
    // BIGNUMs from key generation (like 'e' and 'n') are positive.
    if (bn_buf[0] & 0x80) {
        uint32_t net_len = htonl(static_cast<uint32_t>(len + 1));
        const unsigned char* len_bytes = reinterpret_cast<const unsigned char*>(&net_len);
        buf.insert(buf.end(), len_bytes, len_bytes + sizeof(uint32_t));
        buf.push_back(0x00); // Prepend the zero byte
        buf.insert(buf.end(), bn_buf.begin(), bn_buf.end());
    } else {
        uint32_t net_len = htonl(static_cast<uint32_t>(len));
        const unsigned char* len_bytes = reinterpret_cast<const unsigned char*>(&net_len);
        buf.insert(buf.end(), len_bytes, len_bytes + sizeof(uint32_t));
        buf.insert(buf.end(), bn_buf.begin(), bn_buf.end());
    }
}

// Helper for Base64 encoding using OpenSSL BIOs (no newlines)
std::string base64_encode(const unsigned char* data, size_t len) {
    if (len == 0) return ""; // Handle empty input

    BIOPtr bio_mem(BIO_new(BIO_s_mem()));
    BIOPtr bio_b64(BIO_new(BIO_f_base64()));
    if (!bio_mem || !bio_b64) {
         throw std::runtime_error("BIO_new failed for Base64 encoding.");
    }

    BIO_set_flags(bio_b64.get(), BIO_FLAGS_BASE64_NO_NL); // No newlines in output
    BIO* chain_head = BIO_push(bio_b64.get(), bio_mem.get()); // Order matters!
    if (!chain_head) {
         throw std::runtime_error("BIO_push failed for Base64 encoding.");
    }
    // Detach bio_mem from unique_ptr management as bio_b64 now owns it via the chain
    (void)bio_mem.release();

    // Write data through the chain
    int bytes_written = BIO_write(chain_head, data, len);
    if (bytes_written <= 0) {
        // Error in BIO_write might mean we need to check BIO error queue or just report failure
        // BIO_free_all will be called by bio_b64 unique_ptr
        throw std::runtime_error("BIO_write (base64) failed. Bytes written: " + std::to_string(bytes_written) + ". Error: " + get_openssl_error());
    }
     if (static_cast<size_t>(bytes_written) != len) {
         // Should ideally write all data unless error
         throw std::runtime_error("BIO_write (base64) did not write all bytes.");
     }

    // Flush the chain
    if (BIO_flush(chain_head) != 1) {
        // BIO_free_all will be called by bio_b64 unique_ptr
        throw std::runtime_error("BIO_flush (base64) failed: " + get_openssl_error());
    }

    // Retrieve data from the *memory* BIO (which is at the end of the chain)
    // We need the raw pointer to the memory BIO which bio_b64 owns.
    BIO* mem_bio_raw = BIO_find_type(chain_head, BIO_TYPE_MEM);
    if (!mem_bio_raw) {
        throw std::runtime_error("Could not find memory BIO in chain after base64 encoding.");
    }
    char* output_ptr = nullptr;
    long output_len = BIO_get_mem_data(mem_bio_raw, &output_ptr);

    if (output_len < 0) { // Should not happen if flush succeeded
        throw std::runtime_error("BIO_get_mem_data failed after base64 encoding. Length: " + std::to_string(output_len));
    }
    if (output_len == 0 || !output_ptr) {
        return ""; // Valid empty result
    }

    std::string result(output_ptr, output_len);
    // bio_b64 unique_ptr will call BIO_free_all on the chain_head upon exit
    return result;
}


// --- generate_key_pair_to_fd Implementation (with OpenSSH Public Key) ---
KeyOperationResult generate_key_pair_to_fd(
    const std::string& algorithm,
    const std::string& password,
    int private_key_fd,
    int public_key_fd,
    int bits)
{
    KeyOperationResult result = {false, "", ""};
    FILE* private_fp = nullptr;
    FILE* public_fp = nullptr; // Will use fputs directly
    BIOPtr bio_private = nullptr; // Still need BIO for PEM private key writing
    // No bio_public needed anymore
    EVPKeyPtr pkey = nullptr;
    EVPKeyCtxPtr ctx = nullptr;

    // Initialize OpenSSL error strings and load algorithms (can be done once per process ideally)
    ERR_load_crypto_strings();
    OpenSSL_add_all_algorithms(); // For OpenSSL 1.1.1, EVP_cleanup is deprecated/no-op

    try {
        // --- Validate FDs ---
        if (private_key_fd < 0 || public_key_fd < 0) {
            throw std::runtime_error("Invalid file descriptor provided.");
        }

        // --- Convert fds to FILE* ---
        // Use "wb" for private key as it might be binary encrypted PEM.
        // Use "w" (text mode) for public key as OpenSSH format is text.
        private_fp = fdopen(private_key_fd, "wb");
        if (!private_fp) {
            throw std::runtime_error("Failed to open private key file descriptor (fdopen error)");
        }
        // Ensure public_fp is managed carefully if private_fp succeeded but this fails
        public_fp = fdopen(public_key_fd, "w"); // Use text mode for OpenSSH public key
        if (!public_fp) {
            // If public fails, we need to handle the already opened private_fp.
            // Since we rely on eTS closing the fd, we *don't* call fclose(private_fp) here.
            throw std::runtime_error("Failed to open public key file descriptor (fdopen error)");
        }

        // --- Generate Key based on algorithm string ---
        if (algorithm == "RSA") {
            // --- RSA Key Generation ---
            RSAPtr rsa(RSA_new());
            if (!rsa) throw std::runtime_error("RSA_new failed: " + get_openssl_error());

            BIGNUMPtr bn(BN_new());
            if (!bn) throw std::runtime_error("BN_new failed: " + get_openssl_error());
            if (!BN_set_word(bn.get(), RSA_F4)) { // Use 65537 as public exponent
                 throw std::runtime_error("BN_set_word failed: " + get_openssl_error());
            }

            if (!RSA_generate_key_ex(rsa.get(), bits, bn.get(), nullptr)) {
                throw std::runtime_error("RSA_generate_key_ex failed: " + get_openssl_error());
            }

            // Assign RSA key to the generic EVP_PKEY structure
            pkey.reset(EVP_PKEY_new());
            if (!pkey) throw std::runtime_error("EVP_PKEY_new (for RSA) failed: " + get_openssl_error());
            if (!EVP_PKEY_set1_RSA(pkey.get(), rsa.get())) {
                throw std::runtime_error("EVP_PKEY_set1_RSA failed: " + get_openssl_error());
            }
            // RSA unique_ptr will be released automatically

        } else if (algorithm == "ECDSA") {
            // --- ECDSA Key Generation ---
            // TODO: Allow specifying curve via algorithm string (e.g., "ECDSA-P384") or parameter
            int curve_nid = NID_X9_62_prime256v1; // Default to P-256 (secp256r1)
            // Add logic here to parse 'algorithm' or add a 'curve' parameter to select NID

            ctx.reset(EVP_PKEY_CTX_new_id(EVP_PKEY_EC, NULL));
            if (!ctx) throw std::runtime_error("EVP_PKEY_CTX_new_id (EC) failed: " + get_openssl_error());

            if (EVP_PKEY_keygen_init(ctx.get()) <= 0) {
                 throw std::runtime_error("EVP_PKEY_keygen_init (EC) failed: " + get_openssl_error());
            }

            if (EVP_PKEY_CTX_set_ec_paramgen_curve_nid(ctx.get(), curve_nid) <= 0) {
                 throw std::runtime_error("EVP_PKEY_CTX_set_ec_paramgen_curve_nid failed: " + get_openssl_error());
            }

            // Generate the key directly into pkey
            EVP_PKEY *raw_pkey = nullptr;
            if (EVP_PKEY_keygen(ctx.get(), &raw_pkey) <= 0) {
                 throw std::runtime_error("EVP_PKEY_keygen (EC) failed: " + get_openssl_error());
            }
            pkey.reset(raw_pkey); // Assign the generated key to the smart pointer

        } else if (algorithm == "ED25519") {
             // --- Ed25519 Key Generation ---
             // 'bits' parameter is ignored for Ed25519
            ctx.reset(EVP_PKEY_CTX_new_id(EVP_PKEY_ED25519, NULL));
             if (!ctx) throw std::runtime_error("EVP_PKEY_CTX_new_id (ED25519) failed: " + get_openssl_error());

             if (EVP_PKEY_keygen_init(ctx.get()) <= 0) {
                 throw std::runtime_error("EVP_PKEY_keygen_init (ED25519) failed: " + get_openssl_error());
             }

             // Generate the key directly into pkey
             EVP_PKEY *raw_pkey = nullptr;
             if (EVP_PKEY_keygen(ctx.get(), &raw_pkey) <= 0) {
                 throw std::runtime_error("EVP_PKEY_keygen (ED25519) failed: " + get_openssl_error());
             }
             pkey.reset(raw_pkey);

        } else {
             // --- Unsupported Algorithm ---
              if (algorithm.empty()) {
                  throw std::runtime_error("Key generation algorithm cannot be empty.");
              } else {
                  throw std::runtime_error("Unsupported key generation algorithm: " + algorithm);
              }
        }

        // --- Create BIO for Private Key writing ---
        bio_private.reset(BIO_new_fp(private_fp, BIO_NOCLOSE));
        if (!bio_private) throw std::runtime_error("BIO_new_fp (private) failed: " + get_openssl_error());

        // --- Write Private Key (PKCS#8 format, potentially encrypted) ---
        const EVP_CIPHER* cipher = nullptr;
        if (!password.empty()) {
            cipher = EVP_aes_256_cbc(); // Recommended cipher
            if (!cipher) throw std::runtime_error("Could not get AES 256 CBC cipher: " + get_openssl_error());
        }

        // Use PKCS#8 for better compatibility
        if (!PEM_write_bio_PKCS8PrivateKey(bio_private.get(), pkey.get(), cipher,
                                           (char*)password.c_str(),
                                           (int)password.length(),
                                           nullptr, nullptr)) // No callback for password needed here
        {
            throw std::runtime_error("PEM_write_bio_PKCS8PrivateKey failed: " + get_openssl_error());
        }
         if (fflush(private_fp) != 0) { // Ensure data is flushed
            throw std::runtime_error("fflush (private) failed");
        }
        // Private key writing done.

        // --- Generate and Write Public Key in OpenSSH Format ---
        std::string openssh_pubkey_line;
        { // Scope for temporary serialization variables
            std::vector<unsigned char> serialized_data;
            std::string key_type_str_ssh; // e.g., "ssh-rsa", "ecdsa-sha2-nistp256"
            int pkey_id = EVP_PKEY_base_id(pkey.get());

            if (pkey_id == EVP_PKEY_RSA) {
                key_type_str_ssh = "ssh-rsa";
                RSA* rsa_key = EVP_PKEY_get0_RSA(pkey.get()); // Use get0 for non-owning pointer
                if (!rsa_key) throw std::runtime_error("EVP_PKEY_get0_RSA failed.");
                const BIGNUM *n = nullptr, *e = nullptr;
                RSA_get0_key(rsa_key, &n, &e, nullptr); // Get public components
                if (!n || !e) throw std::runtime_error("RSA_get0_key failed to get n or e.");

                serialize_ssh_string(serialized_data, key_type_str_ssh);
                serialize_ssh_mpint(serialized_data, e);
                serialize_ssh_mpint(serialized_data, n);

            } else if (pkey_id == EVP_PKEY_EC) {
                EC_KEY* ec_key = EVP_PKEY_get0_EC_KEY(pkey.get());
                if (!ec_key) throw std::runtime_error("EVP_PKEY_get0_EC_KEY failed.");
                const EC_GROUP* group = EC_KEY_get0_group(ec_key);
                const EC_POINT* point = EC_KEY_get0_public_key(ec_key);
                if (!group || !point) throw std::runtime_error("EC_KEY_get0_group or _public_key failed.");

                int curve_nid = EC_GROUP_get_curve_name(group);
                std::string curve_name_ssh; // e.g., "nistp256"
                switch (curve_nid) {
                    case NID_X9_62_prime256v1: // secp256r1
                        curve_name_ssh = "nistp256";
                        key_type_str_ssh = "ecdsa-sha2-nistp256";
                        break;
                    case NID_secp384r1:
                        curve_name_ssh = "nistp384";
                        key_type_str_ssh = "ecdsa-sha2-nistp384";
                        break;
                    case NID_secp521r1:
                        curve_name_ssh = "nistp521";
                        key_type_str_ssh = "ecdsa-sha2-nistp521";
                        break;
                    // Add other curves supported by OpenSSH if needed (e.g., Koblitz curves if using OpenSSL > 1.1.1)
                    default:
                        throw std::runtime_error("Unsupported EC curve for OpenSSH format: NID " + std::to_string(curve_nid) + " (" + OBJ_nid2sn(curve_nid) + ")");
                }

                // Get public key point as uncompressed octet string
                size_t point_len = EC_POINT_point2oct(group, point, POINT_CONVERSION_UNCOMPRESSED, nullptr, 0, nullptr);
                if (point_len == 0) throw std::runtime_error("EC_POINT_point2oct failed (determining size): " + get_openssl_error());
                std::vector<unsigned char> point_buf(point_len);
                size_t written_len = EC_POINT_point2oct(group, point, POINT_CONVERSION_UNCOMPRESSED, point_buf.data(), point_len, nullptr);
                if (written_len != point_len) { // Check if conversion wrote expected length
                     throw std::runtime_error("EC_POINT_point2oct failed (conversion): " + get_openssl_error());
                }

                // Serialize: key_type_string, curve_name_string, point_string
                serialize_ssh_string(serialized_data, key_type_str_ssh);
                serialize_ssh_string(serialized_data, curve_name_ssh);
                serialize_ssh_string(serialized_data, point_buf.data(), point_buf.size());

            } else if (pkey_id == EVP_PKEY_ED25519) {
                key_type_str_ssh = "ssh-ed25519";
                size_t raw_len = 0;
                // Get length first (required by API)
                if (EVP_PKEY_get_raw_public_key(pkey.get(), nullptr, &raw_len) <= 0) {
                     throw std::runtime_error("EVP_PKEY_get_raw_public_key failed (getting length): " + get_openssl_error());
                }
                 // Ed25519 public key is always 32 bytes
                 if (raw_len == 0) {
                     throw std::runtime_error("EVP_PKEY_get_raw_public_key returned zero length for Ed25519.");
                 }
                  if (raw_len != 32) { // Sanity check
                       throw std::runtime_error("Unexpected raw public key length for Ed25519: " + std::to_string(raw_len));
                  }

                std::vector<unsigned char> raw_pub_key(raw_len);
                if (EVP_PKEY_get_raw_public_key(pkey.get(), raw_pub_key.data(), &raw_len) <= 0) {
                    throw std::runtime_error("EVP_PKEY_get_raw_public_key failed (getting data): " + get_openssl_error());
                }

                // Serialize: key_type_string, raw_key_bytes_string
                serialize_ssh_string(serialized_data, key_type_str_ssh);
                serialize_ssh_string(serialized_data, raw_pub_key.data(), raw_pub_key.size());

            } else {
                 // Should have been caught by algorithm check earlier, but defensive check
                 throw std::runtime_error("Unsupported key type for OpenSSH public key format: ID " + std::to_string(pkey_id));
            }

            // Base64 encode the serialized data
            std::string base64_data = base64_encode(serialized_data.data(), serialized_data.size());

            // Construct the final line (using a simple comment, add newline!)
            openssh_pubkey_line = key_type_str_ssh + " " + base64_data + " generated-key\n";

        } // End scope for temporary serialization variables

        // Write the OpenSSH line directly using the FILE* obtained from fdopen
        if (fputs(openssh_pubkey_line.c_str(), public_fp) == EOF) {
            // Check ferror(public_fp) for details if needed
            throw std::runtime_error("Failed to write OpenSSH public key to file descriptor (fputs error)");
        }
        if (fflush(public_fp) != 0) { // Ensure data is flushed to the underlying fd
            // Check errno if needed
            throw std::runtime_error("fflush (public) failed");
        }
        // Public key writing done.

        result.success = true;

    } catch (const std::exception& e) {
        result.success = false;
        result.error_message = e.what();
        // Do not call fclose(private_fp) or fclose(public_fp) here as eTS owns the fd.
        // Ensure FILE* are nullified if fdopen failed partially? No, fdopen handles that.
        // The FDs themselves remain open and managed by the caller.
    } catch (...) {
        result.success = false;
        result.error_message = "An unknown error occurred during key generation.";
    }

    // Clean up OpenSSL library allocations (errors, algorithms)
    // EVP_cleanup(); // Deprecated in 1.1.0+, no-op
    ERR_free_strings(); // Still good practice

    // Note: Smart pointers (BIOPtr, EVPKeyPtr, RSAPtr, BIGNUMPtr, EVPKeyCtxPtr) automatically free their OpenSSL resources.
    // FILE* pointers (private_fp, public_fp) are NOT closed here because BIO_NOCLOSE was used for private
    // and public key was written directly to FILE* derived from an fd managed externally.

    return result;
}

// --- Password Callback for PEM_read_bio_PrivateKey ---
// This function is called by OpenSSL to get the password.
// userdata MUST point to the std::string containing the password.
int local_pem_password_callback(char *buf, int size, int rwflag, void *userdata) {
    if (!userdata) return 0; // No userdata provided
    const std::string* password_ptr = static_cast<const std::string*>(userdata);
    if (password_ptr->empty()) {
        // OpenSSL might call this even if no password was expected,
        // return 0 to indicate no password / failure to provide one.
        return 0;
    }

    // Ensure buffer size is positive
    if (size <= 0) {
        return 0; // Invalid buffer size
    }

    // Copy password, ensuring null termination and respecting buffer size
    strncpy(buf, password_ptr->c_str(), size - 1);
    buf[size - 1] = '\0'; // Ensure null termination even if strncpy filled buffer

    // Return the actual length of the password copied (strlen, not password_ptr->length())
    return static_cast<int>(strlen(buf));
}

// --- decrypt_private_key_from_fd Implementation (Unchanged) ---
KeyOperationResult decrypt_private_key_from_fd(
    int private_key_fd,
    const std::string& password)
{
    KeyOperationResult result = {false, "", ""};
    FILE* private_fp = nullptr;
    BIOPtr bio_read = nullptr;
    EVPKeyPtr pkey = nullptr;
    BIOPtr bio_mem_write = nullptr; // To write decrypted key to string

    ERR_load_crypto_strings();
    // OpenSSL_add_all_algorithms(); // Already called in generate? If called separately, may need it.

    try {
        if (private_key_fd < 0) {
            throw std::runtime_error("Invalid file descriptor provided.");
        }
         if (password.empty()) {
             // While OpenSSL *might* sometimes decrypt keys with empty passwords if they
             // were created that way (depends on PEM format/library version),
             // requiring a password for decryption is safer and clearer.
            throw std::runtime_error("Password cannot be empty for decryption function.");
        }

        // --- Convert fd to FILE* ---
        private_fp = fdopen(private_key_fd, "rb"); // Read binary mode
        if (!private_fp) {
            throw std::runtime_error("Failed to open private key file descriptor for reading (fdopen)");
        }

        // --- Create BIO for reading (using BIO_NOCLOSE) ---
        bio_read.reset(BIO_new_fp(private_fp, BIO_NOCLOSE));
        if (!bio_read) throw std::runtime_error("BIO_new_fp (read) failed: " + get_openssl_error());

        // --- Read and decrypt Private Key using password callback ---
        // Pass the address of the password string as userdata
        pkey.reset(PEM_read_bio_PrivateKey(bio_read.get(), nullptr, local_pem_password_callback, (void*)&password));

        if (!pkey) {
            unsigned long err_code = ERR_peek_last_error(); // Peek error before calling get_openssl_error
            std::string ssl_err = get_openssl_error(); // consumes the error
            // Check for specific password-related errors after getting general message
            if (ERR_GET_LIB(err_code) == ERR_LIB_PEM &&
                (ERR_GET_REASON(err_code) == PEM_R_BAD_PASSWORD_READ || ERR_GET_REASON(err_code) == PEM_R_BAD_DECRYPT)) {
                // Provide a more user-friendly message for common password issues
                throw std::runtime_error("Decryption failed: Incorrect password or key format incompatible with password.");
            } else if (ERR_GET_LIB(err_code) == ERR_LIB_EVP && ERR_GET_REASON(err_code) == EVP_R_BAD_DECRYPT) {
                 throw std::runtime_error("Decryption failed: Bad decrypt operation (check password/key).");
            }
            else {
                // General failure
                throw std::runtime_error("PEM_read_bio_PrivateKey failed: " + ssl_err + " (Code: " + std::to_string(err_code) + ")");
            }
        }

        // --- Convert decrypted key back to PEM string (unencrypted PKCS#8) ---
        bio_mem_write.reset(BIO_new(BIO_s_mem()));
        if (!bio_mem_write) throw std::runtime_error("BIO_new (mem) failed: " + get_openssl_error());

        // Write in standard PKCS#8 format (unencrypted)
        // Pass NULL for cipher, password, etc.
        if (!PEM_write_bio_PKCS8PrivateKey(bio_mem_write.get(), pkey.get(), nullptr, nullptr, 0, nullptr, nullptr)) {
            throw std::runtime_error("PEM_write_bio_PKCS8PrivateKey (to mem) failed: " + get_openssl_error());
        }

        // --- Extract PEM string from memory BIO ---
        char* pem_data = nullptr;
        long pem_len = BIO_get_mem_data(bio_mem_write.get(), &pem_data);
        if (pem_len < 0) { // Error condition
            throw std::runtime_error("BIO_get_mem_data failed after writing decrypted key.");
        }
        if (pem_len == 0 || !pem_data) { // Should not happen if write succeeded, but check
             throw std::runtime_error("BIO_get_mem_data returned empty data after writing decrypted key.");
        }

        result.decrypted_pem.assign(pem_data, pem_len);
        result.success = true;

    } catch (const std::exception& e) {
        result.success = false;
        result.error_message = e.what();
    } catch (...) {
        result.success = false;
        result.error_message = "An unknown error occurred during key decryption.";
    }

    // EVP_cleanup(); // Deprecated
    ERR_free_strings(); // Clean up error strings loaded at start

    // Smart pointers manage BIOs and EVP_PKEY.
    // private_fp is not closed due to BIO_NOCLOSE.

    return result;
}