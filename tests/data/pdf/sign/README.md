# Test signing fixtures (test-only keys, no licensing concerns)
#
# Generated locally with OpenSSL 3.6.3. The .key files are throwaway
# test keys. To regenerate, run from this directory:
#
#   # CA (CA:true, keyCertSign)
#   openssl req -x509 -newkey rsa:2048 -keyout ca.key -out ca.cert.pem \
#     -days 3650 -nodes -subj "/CN=Test CA/O=opendocs tests" \
#     -addext "basicConstraints=critical,CA:true" \
#     -addext "keyUsage=critical,keyCertSign,cRLSign,digitalSignature"
#   openssl x509 -in ca.cert.pem -outform DER -out ca.cert.der
#
#   # Leaf (codeSigning EKU), signed by the CA
#   openssl req -newkey rsa:2048 -keyout leaf.key -out leaf.csr -nodes \
#     -subj "/CN=Test Signer/O=opendocs tests"
#   printf 'basicConstraints=CA:false\nkeyUsage=critical,digitalSignature\n' > leaf.ext
#   printf 'extendedKeyUsage=codeSigning\nsubjectKeyIdentifier=hash\n' >> leaf.ext
#   printf 'authorityKeyIdentifier=keyid\n' >> leaf.ext
#   openssl x509 -req -in leaf.csr -CA ca.cert.pem -CAkey ca.key \
#     -CAcreateserial -days 825 -extfile leaf.ext -out leaf.cert.pem
#   openssl x509 -in leaf.cert.pem -outform DER -out leaf.cert.der
#
#   # Self-signed P-256 EC leaf (ECDSA verify path)
#   openssl ecparam -genkey -name prime256v1 -noout -out ec.key
#   openssl req -x509 -new -key ec.key -out ec.cert.pem -days 825 \
#     -subj "/CN=Test EC/O=opendocs tests" \
#     -addext "basicConstraints=critical,CA:false" \
#     -addext "keyUsage=critical,digitalSignature" \
#     -addext "extendedKeyUsage=codeSigning"
#   openssl x509 -in ec.cert.pem -outform DER -out ec.cert.der
#
#   # Self-signed TSA (RFC 3161 testing; EKU timeStamping, critical)
#   openssl req -x509 -newkey rsa:2048 -keyout tsa.key \
#     -out tsa.cert.pem -days 825 -nodes \
#     -subj "/CN=Test TSA/O=opendocs tests" \
#     -addext "basicConstraints=critical,CA:false" \
#     -addext "keyUsage=critical,digitalSignature" \
#     -addext "extendedKeyUsage=critical,timeStamping"
#   openssl x509 -in tsa.cert.pem -outform DER -out tsa.cert.der
#
# Only the .cert.der/.cert.pem/.key files used by tests are checked
# in (.csr/.srl scratch files are not).
