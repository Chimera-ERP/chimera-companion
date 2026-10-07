import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:basic_utils/basic_utils.dart';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/signers/ecdsa_signer.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'offline_grant.dart';

int verifyOperatorAssertion(
  Map<String, dynamic> assertion,
  Map<String, dynamic> credential,
  Map<String, dynamic> policy,
  String challenge,
  String origin,
  int previousCounter,
) {
  if (assertion['id'] != credential['id'] || policy['origin'] != origin) {
    throw const FormatException('Operator credential or origin mismatch');
  }
  final response = assertion['response'] as Map<String, dynamic>;
  final auth = decodeBase64Url(response['authenticatorData'] as String);
  final client = decodeBase64Url(response['clientDataJSON'] as String);
  final signature = decodeBase64Url(response['signature'] as String);
  if (auth.length < 37 ||
      auth.length > 2048 ||
      client.length > 8192 ||
      signature.length > 2048) {
    throw const FormatException('Invalid authenticator data');
  }
  final data = jsonDecode(utf8.decode(client)) as Map<String, dynamic>;
  if (data['type'] != 'webauthn.get' ||
      data['challenge'] != challenge ||
      data['origin'] != origin ||
      data['crossOrigin'] == true ||
      (auth[32] & 5) != 5) {
    throw const FormatException('Fresh verified passkey required');
  }
  final rpHash = sha256.convert(utf8.encode(policy['rpId'] as String)).bytes;
  if (!List.generate(32, (i) => auth[i] == rpHash[i]).every((same) => same)) {
    throw const FormatException('WebAuthn RP mismatch');
  }
  final counter = ByteData.sublistView(auth).getUint32(33);
  if ((previousCounter != 0 || counter != 0) && counter <= previousCounter) {
    throw const FormatException('Authenticator counter replay');
  }
  final signed = Uint8List.fromList([...auth, ...sha256.convert(client).bytes]);
  final key = decodeBase64Url(credential['publicKey'] as String);
  bool valid = false;
  if (credential['algorithm'] == -7) {
    final parser = ASN1Parser(signature);
    final sequence = parser.nextObject() as ASN1Sequence;
    if (parser.hasNext() || sequence.elements?.length != 2) {
      throw const FormatException('Invalid ECDSA signature');
    }
    final verifier = ECDSASigner(SHA256Digest())
      ..init(
        false,
        PublicKeyParameter<ECPublicKey>(
          CryptoUtils.ecPublicKeyFromDerBytes(key),
        ),
      );
    valid = verifier.verifySignature(
      signed,
      ECSignature(
        (sequence.elements![0] as ASN1Integer).integer!,
        (sequence.elements![1] as ASN1Integer).integer!,
      ),
    );
  } else if (credential['algorithm'] == -257) {
    valid = CryptoUtils.rsaVerify(
      CryptoUtils.rsaPublicKeyFromDERBytes(key),
      signed,
      signature,
    );
  }
  if (!valid) throw const FormatException('Invalid operator signature');
  return counter;
}
