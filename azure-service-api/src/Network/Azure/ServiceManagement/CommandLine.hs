import Network.Azure.ServiceManagement
  ( fileReadCertificate
  )
import System.Environment (getArgs)

main :: IO ()
main = do
  [cert] <- getArgs
  x509 <- fileReadCertificate cert
  print x509
