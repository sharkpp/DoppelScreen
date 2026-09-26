#include "server/tls_identity.hpp"

#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <shlobj.h>
#include <wincrypt.h>
#include <algorithm>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <stdexcept>

namespace doppelscreen {
namespace {
template <typename T, void (*Free)(T*)>
using openssl_ptr = std::unique_ptr<T, decltype(Free)>;

void check(bool value, const char* operation) {
  if (!value) throw std::runtime_error(operation);
}

std::filesystem::path identity_directory() {
  PWSTR local = nullptr;
  check(SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE, nullptr, &local)),
        "SHGetKnownFolderPath");
  const std::filesystem::path result = std::filesystem::path(local) / L"DoppelScreen" / L"tls";
  CoTaskMemFree(local);
  std::filesystem::create_directories(result);
  return result;
}

FILE* open_file(const std::filesystem::path& path, const wchar_t* mode) {
  FILE* file = nullptr;
  _wfopen_s(&file, path.c_str(), mode);
  return file;
}

bool load_identity(const std::filesystem::path& directory,
                   const std::vector<std::string>& addresses,
                   openssl_ptr<EVP_PKEY, EVP_PKEY_free>& key,
                   openssl_ptr<X509, X509_free>& certificate) {
  auto* certificate_file = open_file(directory / L"certificate.pem", L"rb");
  std::ifstream protected_key_file(directory / L"private-key.bin", std::ios::binary);
  if (!certificate_file || !protected_key_file) {
    if (certificate_file) fclose(certificate_file);
    return false;
  }
  certificate.reset(PEM_read_X509(certificate_file, nullptr, nullptr, nullptr));
  fclose(certificate_file);
  const std::vector<unsigned char> protected_key{
      std::istreambuf_iterator<char>(protected_key_file), std::istreambuf_iterator<char>()};
  DATA_BLOB encrypted{static_cast<DWORD>(protected_key.size()),
                      const_cast<BYTE*>(protected_key.data())};
  DATA_BLOB clear{};
  if (!CryptUnprotectData(&encrypted, nullptr, nullptr, nullptr, nullptr,
                          CRYPTPROTECT_UI_FORBIDDEN, &clear)) return false;
  const unsigned char* cursor = clear.pbData;
  key.reset(d2i_AutoPrivateKey(nullptr, &cursor, clear.cbData));
  LocalFree(clear.pbData);
  if (!certificate || !key || X509_cmp_current_time(X509_get0_notAfter(certificate.get())) <= 0 ||
      X509_check_private_key(certificate.get(), key.get()) != 1) return false;
  return std::ranges::all_of(addresses, [&](const auto& address) {
    return X509_check_ip_asc(certificate.get(), address.c_str(), 0) == 1;
  });
}

void add_dns_name(GENERAL_NAMES* names, const char* value) {
  openssl_ptr<GENERAL_NAME, GENERAL_NAME_free> name(GENERAL_NAME_new(), GENERAL_NAME_free);
  openssl_ptr<ASN1_IA5STRING, ASN1_IA5STRING_free> dns(ASN1_IA5STRING_new(),
                                                       ASN1_IA5STRING_free);
  check(name != nullptr && dns != nullptr &&
            ASN1_STRING_set(dns.get(), value, static_cast<int>(std::strlen(value))) == 1,
        "create DNS subjectAltName");
  GENERAL_NAME_set0_value(name.get(), GEN_DNS, dns.release());
  check(sk_GENERAL_NAME_push(names, name.get()) != 0, "add DNS subjectAltName");
  name.release();
}

void add_ip_address(GENERAL_NAMES* names, const std::string& value) {
  openssl_ptr<GENERAL_NAME, GENERAL_NAME_free> name(GENERAL_NAME_new(), GENERAL_NAME_free);
  openssl_ptr<ASN1_OCTET_STRING, ASN1_OCTET_STRING_free> address(
      a2i_IPADDRESS(value.c_str()), ASN1_OCTET_STRING_free);
  check(name != nullptr && address != nullptr, "create IP subjectAltName");
  GENERAL_NAME_set0_value(name.get(), GEN_IPADD, address.release());
  check(sk_GENERAL_NAME_push(names, name.get()) != 0, "add IP subjectAltName");
  name.release();
}

void save_identity(const std::filesystem::path& directory, EVP_PKEY* key, X509* certificate) {
  auto* certificate_file = open_file(directory / L"certificate.pem", L"wb");
  if (!certificate_file) {
    if (certificate_file) fclose(certificate_file);
    throw std::runtime_error("open identity files");
  }
  const auto certificate_ok = PEM_write_X509(certificate_file, certificate) == 1;
  fclose(certificate_file);
  check(certificate_ok, "write certificate file");

  const auto key_size = i2d_PrivateKey(key, nullptr);
  check(key_size > 0, "encode private key");
  std::vector<unsigned char> clear_key(static_cast<std::size_t>(key_size));
  auto* cursor = clear_key.data();
  check(i2d_PrivateKey(key, &cursor) == key_size, "encode private key");
  DATA_BLOB clear{static_cast<DWORD>(clear_key.size()), clear_key.data()};
  DATA_BLOB encrypted{};
  check(CryptProtectData(&clear, L"DoppelScreen TLS private key", nullptr, nullptr, nullptr,
                         CRYPTPROTECT_UI_FORBIDDEN, &encrypted), "CryptProtectData");
  std::ofstream key_file(directory / L"private-key.bin", std::ios::binary | std::ios::trunc);
  key_file.write(reinterpret_cast<const char*>(encrypted.pbData), encrypted.cbData);
  const auto key_ok = key_file.good();
  LocalFree(encrypted.pbData);
  check(key_ok, "write private key file");
}
}  // namespace

void configure_persistent_identity(boost::asio::ssl::context& context,
                                   const std::vector<std::string>& addresses) {
  const auto directory = identity_directory();
  openssl_ptr<EVP_PKEY, EVP_PKEY_free> key(nullptr, EVP_PKEY_free);
  openssl_ptr<X509, X509_free> certificate(nullptr, X509_free);
  if (!load_identity(directory, addresses, key, certificate)) {
    key.reset(EVP_RSA_gen(2048));
    check(key != nullptr, "EVP_RSA_gen");
    certificate.reset(X509_new());
    check(certificate != nullptr, "X509_new");
    X509_set_version(certificate.get(), 2);
    ASN1_INTEGER_set(X509_get_serialNumber(certificate.get()), 1);
    X509_gmtime_adj(X509_getm_notBefore(certificate.get()), 0);
    X509_gmtime_adj(X509_getm_notAfter(certificate.get()), 365L * 24 * 60 * 60);
    check(X509_set_pubkey(certificate.get(), key.get()) == 1, "X509_set_pubkey");
    auto* name = X509_get_subject_name(certificate.get());
    X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC,
                               reinterpret_cast<const unsigned char*>("DoppelScreen"), -1, -1, 0);
    X509_set_issuer_name(certificate.get(), name);

    openssl_ptr<GENERAL_NAMES, GENERAL_NAMES_free> names(GENERAL_NAMES_new(),
                                                         GENERAL_NAMES_free);
    check(names != nullptr, "create subjectAltName");
    add_dns_name(names.get(), "localhost");
    add_ip_address(names.get(), "127.0.0.1");
    for (const auto& address : addresses) add_ip_address(names.get(), address);
    check(X509_add1_ext_i2d(certificate.get(), NID_subject_alt_name, names.get(), 0,
                            X509V3_ADD_DEFAULT) == 1,
          "subjectAltName");
    check(X509_sign(certificate.get(), key.get(), EVP_sha256()) > 0, "X509_sign");
    save_identity(directory, key.get(), certificate.get());
  }
  auto* native = context.native_handle();
  check(SSL_CTX_use_certificate(native, certificate.get()) == 1, "SSL_CTX_use_certificate");
  check(SSL_CTX_use_PrivateKey(native, key.get()) == 1, "SSL_CTX_use_PrivateKey");
}

}  // namespace doppelscreen
