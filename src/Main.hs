{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings         #-}

module Main where

import           Control.Applicative      ((<$>), (<*>))
import           Control.Monad
import           Crypto.Hash
import qualified Crypto.PubKey.RSA        as RSA
import qualified Crypto.PubKey.RSA.PKCS15 as RSA
import           Crypto.Random            (MonadRandom)
import           Data.ASN1.BinaryEncoding
import           Data.ASN1.BitArray
import           Data.ASN1.Encoding
import           Data.ASN1.OID
import           Data.ASN1.Parse
import           Data.ASN1.Types
import           Data.Bits
import           Data.ByteArray.Encoding
import qualified Data.ByteString          as B
import qualified Data.ByteString.Base64   as Base64
import qualified Data.ByteString.Char8    as BC
import qualified Data.ByteString.Lazy     as L
import           Data.PEM
import           Data.Typeable
import           Data.X509
import           Data.X509.File
import           Data.X509.Memory
import           Numeric
import           Text.Printf

publicExponent :: Integer
publicExponent = 0x10001 -- 65537

rsaKeySize :: Int
rsaKeySize = 256 -- 2048 bits

data X520Attribute =
     X520CommonName
     | X520SerialNumber
     | X520Name
     | X520Surname
     | X520GivenName
     | X520Initials
     | X520GenerationQualifier
     | X520CountryName
     | X520LocalityName
     | X520StateOrProvinceName
     | X520StreetAddress
     | X520OrganizationName
     | X520OrganizationalUnitName
     | X520Title
     | X520DNQualifier
     | X520Pseudonym
     | EmailAddress
     | IPAddress
     | DomainComponent
     | UserId
     deriving (Show, Eq)

instance OIDable X520Attribute where
  getObjectID X520CommonName             = [2,5,4,3]
  getObjectID X520SerialNumber           = [2,5,4,5]
  getObjectID X520Name                   = [2,5,4,41]
  getObjectID X520Surname                = [2,5,4,4]
  getObjectID X520GivenName              = [2,5,4,42]
  getObjectID X520Initials               = [2,5,4,43]
  getObjectID X520GenerationQualifier    = [2,5,4,44]
  getObjectID X520CountryName            = [2,5,4,6]
  getObjectID X520LocalityName           = [2,5,4,7]
  getObjectID X520StateOrProvinceName    = [2,5,4,8]
  getObjectID X520StreetAddress          = [2,5,4,9]
  getObjectID X520OrganizationName       = [2,5,4,10]
  getObjectID X520OrganizationalUnitName = [2,5,4,11]
  getObjectID X520Title                  = [2,5,4,12]
  getObjectID X520DNQualifier            = [2,5,4,46]
  getObjectID X520Pseudonym              = [2,5,4,65]
  getObjectID EmailAddress               = [1,2,840,113549,1,9,1]
  getObjectID IPAddress                  = [1,3,6,1,4,1,42,2,11,2,1]
  getObjectID DomainComponent            = [0,9,2342,19200300,100,1,25]
  getObjectID UserId                     = [0,9,2342,19200300,100,1,1]

instance OIDNameable X520Attribute where
  fromObjectID [2,5,4,3]                    = Just X520CommonName
  fromObjectID [2,5,4,5]                    = Just X520SerialNumber
  fromObjectID [2,5,4,41]                   = Just X520Name
  fromObjectID [2,5,4,4]                    = Just X520Surname
  fromObjectID [2,5,4,42]                   = Just X520GivenName
  fromObjectID [2,5,4,43]                   = Just X520Initials
  fromObjectID [2,5,4,44]                   = Just X520GenerationQualifier
  fromObjectID [2,5,4,6]                    = Just X520CountryName
  fromObjectID [2,5,4,7]                    = Just X520LocalityName
  fromObjectID [2,5,4,8]                    = Just X520StateOrProvinceName
  fromObjectID [2,5,4,9]                    = Just X520StreetAddress
  fromObjectID [2,5,4,10]                   = Just X520OrganizationName
  fromObjectID [2,5,4,11]                   = Just X520OrganizationalUnitName
  fromObjectID [2,5,4,12]                   = Just X520Title
  fromObjectID [2,5,4,46]                   = Just X520DNQualifier
  fromObjectID [2,5,4,65]                   = Just X520Pseudonym
  fromObjectID [1,2,840,113549,1,9,1]       = Just EmailAddress
  fromObjectID [1,3,6,1,4,1,42,2,11,2,1]    = Just IPAddress
  fromObjectID [0,9,2342,19200300,100,1,25] = Just DomainComponent
  fromObjectID [0,9,2342,19200300,100,1,1]  = Just UserId

data PKCS9Attribute =
  forall e . (Extension e, Show e, Eq e, Typeable e) => PKCS9Attribute e

newtype PKCS9Attributes =
  PKCS9Attributes [PKCS9Attribute] deriving (Show, Eq)

instance Show PKCS9Attribute where
  show (PKCS9Attribute e) = show e

instance Eq PKCS9Attribute where
   (PKCS9Attribute x) == (PKCS9Attribute y) =
     case cast y of
       Just y' -> x == y'
       Nothing -> False

newtype X520Attributes =
        X520Attributes [(X520Attribute, String)] deriving (Show, Eq)

data CertificationRequest = CertificationRequest {
  certificationRequestInfo :: CertificationRequestInfo
  , signatureAlgorithm     :: SignatureAlgorithmIdentifier
  , signature              :: Signature
} deriving (Show, Eq)

data CertificationRequestInfo = CertificationRequestInfo {
  version                :: Version
  , subject              :: X520Attributes
  , subjectPublicKeyInfo :: PubKey
  , attributes           :: PKCS9Attributes
} deriving (Show, Eq)

newtype Version = Version Int deriving (Show, Eq)

data SignatureAlgorithmIdentifier =
     SignatureAlgorithmIdentifier SignatureALG deriving (Show, Eq)

newtype Signature =
        Signature B.ByteString deriving (Show, Eq)

instance ASN1Object CertificationRequest where
  toASN1 (CertificationRequest info sigAlg sig) xs =
    Start Sequence :
      (toASN1 info .
       toASN1 sigAlg .
       toASN1 sig)
      (End Sequence : xs)

  fromASN1 (Start Sequence : xs) =
    f $ runParseASN1State p xs
    where
      p = CertificationRequest <$> getObject
                               <*> getObject
                               <*> getObject
      f (Right (req, End Sequence : xs)) = Right (req, xs)
      f (Right xs') =
        Left ("fromASN1: PKCS9.CertificationRequest: unknown format: " ++ show xs')
      f (Left e) = Left e

  fromASN1 xs =
    Left ("fromASN1: PKCS9.CertificationRequest: unknown format: " ++ show xs)

instance ASN1Object Signature where
  toASN1 (Signature bs) xs =
    (BitString $ toBitArray bs 0) : xs

  fromASN1 (BitString s : xs) =
    Right (Signature $ bitArrayGetData s, xs)

  fromASN1 xs =
    Left ("fromASN1: PKCS9.Signature: unknown format: " ++ show xs)

instance ASN1Object CertificationRequestInfo where
  toASN1 (CertificationRequestInfo version subject pubKey attributes) xs =
    Start Sequence :
      (toASN1 version .
       toASN1 subject .
       toASN1 pubKey .
       toASN1 attributes)
      (End Sequence : xs)

  fromASN1 (Start Sequence : xs) =
    f $ runParseASN1State p xs
    where
      p = CertificationRequestInfo <$> getObject
                                   <*> getObject
                                   <*> getObject
                                   <*> getObject
      f (Right (req, End Sequence : xs)) = Right (req, xs)
      f (Right xs') =
        Left ("fromASN1: PKCS9.CertificationRequestInfo: unknown format: " ++ show xs')
      f (Left e) = Left e

  fromASN1 xs =
    Left ("fromASN1: PKCS9.CertificationRequestInfo: unknown format: " ++ show xs)

instance ASN1Object Version where
  toASN1 (Version v) xs =
    (IntVal $ fromIntegral v) : xs

  fromASN1 (IntVal n : xs) =
    Right (Version $ fromIntegral n, xs)

  fromASN1 xs =
    Left ("fromASN1: PKCS9.Version: unknown format: " ++ show xs)

instance ASN1Object X520Attributes where
  toASN1 (X520Attributes attrs) xs =
    Start Sequence :
      attrSet ++
      End Sequence : xs
    where
      attrSet = concatMap f attrs
      f (attr, s) = [Start Set, Start Sequence, oid attr, cs s, End Sequence, End Set]
      oid attr = OID $ getObjectID attr
      cs s = ASN1String $ asn1CharacterString UTF8 s

  fromASN1 (Start Sequence : xs) =
    f (X520Attributes []) xs
    where
      f (X520Attributes attrs) (Start Set : Start Sequence : (OID oid) : (ASN1String cs) : End Sequence : End Set : rest) =
        case (fromObjectID oid, asn1CharacterToString cs) of
          (Just attr, Just s) ->
            f (X520Attributes $ (attr, s) : attrs) rest
          _ -> Left ("fromASN1: X520.Attributes: unknown oid: " ++ show oid)
      f attrs (End Sequence : rest) =
        Right (attrs, rest)
      f _ xs' = Left ("fromASN1: X520.Attributes: unknown format: " ++ show xs')

  fromASN1 xs =
    Left ("fromASN1: X520.Attributes: unknown format: " ++ show xs)

instance ASN1Object SignatureAlgorithmIdentifier where
  toASN1 (SignatureAlgorithmIdentifier sigAlg) =
    toASN1 sigAlg

  fromASN1 =
    runParseASN1State $ SignatureAlgorithmIdentifier <$> getObject

instance ASN1Object PKCS9Attribute where
  toASN1 (PKCS9Attribute attr) xs =
    Start Sequence : oid : os : End Sequence : xs
    where
      oid = OID $ extOID attr
      os = (OctetString . encodeASN1' DER . extEncode) attr

  fromASN1 (Start Sequence : OID oid : OctetString os : End Sequence : xs) =
    case oid of
      [2,5,29,14] -> f (decode :: Either String ExtSubjectKeyId)
      [2,5,29,15] -> f (decode :: Either String ExtKeyUsage)
      [2,5,29,17] -> f (decode :: Either String ExtSubjectAltName)
      [2,5,29,19] -> f (decode :: Either String ExtBasicConstraints)
      [2,5,29,31] -> f (decode :: Either String ExtCrlDistributionPoints)
      [2,5,29,35] -> f (decode :: Either String ExtAuthorityKeyId)
      [2,5,29,37] -> f (decode :: Either String ExtExtendedKeyUsage)
      _ -> Left ("fromASN1: PKCS9.Attribute: unknown oid: " ++ show oid)
    where
      decode :: forall e . (Extension e, Show e, Eq e, Typeable e) => Either String e
      decode = case decodeASN1' DER os of
                 Right ds -> extDecode ds
                 Left e -> Left $ show e
      f (Right attr) = Right (PKCS9Attribute attr, xs)
      f (Left e) = Left ("fromASN1: PKCS9.Attribute: " ++ show e)

  fromASN1 xs =
    Left ("fromASN1: PKCS9.Attribute: unknown format: " ++ show xs)

extensionRequestOid :: [Integer]
extensionRequestOid = [1,2,840,113549,1,9,14]

instance ASN1Object PKCS9Attributes where
  toASN1 (PKCS9Attributes exts) xs =
    Start (Container Context 0) :
      ctx ++
      End (Container Context 0) : xs
    where
      ctx = case exts of
              [] -> []
              es ->
                [Start Sequence, extOid, Start Set, Start Sequence] ++
                  extSet ++
                  [End Sequence, End Set, End Sequence]
                where
                  extOid = OID extensionRequestOid
                  extSet = concatMap (flip toASN1 []) es

  fromASN1 (Start (Container Context 0) : xs) =
    f xs
    where
      f (Start Sequence : (OID extOid) : Start Set : Start Sequence : rest) =
        g [] rest
        where
          g exts (End Sequence : End Set : End Sequence : End (Container Context 0) : rest') =
            Right (PKCS9Attributes exts, rest')
          g exts (rest' @ (Start Sequence : _)) =
            case fromASN1 rest' of
              Right (attr, xss) -> g (attr : exts) xss
              Left e -> Left e
          g _ xs' = Left ("fromASN1: PKCS9.Attribute: unknown format: " ++ show xs')
      f (End (Container Context 0) : rest) = Right (PKCS9Attributes [], rest)
      f xs' = Left ("fromASN1: PKCS9.Attributes: unknown format: " ++ show xs')

  fromASN1 xs =
    Left ("fromASN1: PKCS9.Attributes: unknown format: " ++ show xs)

readPEMFile file = do
    content <- B.readFile file
    return $ either error id $ pemParseBS content

encodeDER :: ASN1Object o => o -> BC.ByteString
encodeDER = encodeASN1' DER . flip toASN1 []

decodeDER :: ASN1Object o => BC.ByteString -> Either String (o, [ASN1])
decodeDER bs =
  f asn
  where
    asn = fromASN1 <$> decodeASN1' DER bs
    f = either (Left . show) id

generateCSR :: MonadRandom m => X520Attributes -> PKCS9Attributes -> RSA.PrivateKey -> RSA.PublicKey -> m (Either String BC.ByteString)
generateCSR subject extAttrs privKey pubKey =
  f <$> signature
  where
    f = either (Left . show) (Right . encodeDER . genReq)
    certReq = CertificationRequestInfo {
                version = Version 0
                , subject = subject
                , subjectPublicKeyInfo = PubKeyRSA pubKey
                , attributes = extAttrs
              }
    signature = RSA.signSafer (Just SHA256) privKey $ encodeDER certReq
    genReq s = CertificationRequest {
                 certificationRequestInfo = certReq
                 , signatureAlgorithm = SignatureAlgorithmIdentifier (SignatureALG HashSHA256 PubKeyALG_RSA)
                 , signature = Signature s
               }

main :: IO ()
main = do
     (pubKey, privKey) <- RSA.generate rsaKeySize publicExponent
     let subject = X520Attributes [(X520CommonName, "node.fcomb.io"), (X520OrganizationName, "fcomb")]
     let extAttrs = PKCS9Attributes [PKCS9Attribute $ ExtExtendedKeyUsage [KeyUsagePurpose_ServerAuth, KeyUsagePurpose_CodeSigning], PKCS9Attribute $ ExtKeyUsage [KeyUsage_cRLSign, KeyUsage_digitalSignature]]
     Right bits <- generateCSR subject extAttrs privKey pubKey
     B.writeFile "/tmp/pkcs10.der" bits
     B.writeFile "/tmp/pkcs10.pem" $ pemWriteBS PEM { pemName = "CERTIFICATE REQUEST", pemHeader = [], pemContent = bits }
     let (req) = case decodeDER bits of
                   Right (req @ CertificationRequest {}, _) -> req
     putStrLn $ show req
     return ()
