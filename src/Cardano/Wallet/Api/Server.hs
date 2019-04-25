{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedLabels #-}

-- |
-- Copyright: © 2018-2019 IOHK
-- License: MIT
--
-- API handlers and server using the underlying wallet layer to provide
-- endpoints reachable through HTTP.

module Cardano.Wallet.Api.Server
    ( server
    ) where

import Prelude

import Cardano.Wallet
    ( ErrCreateUnsignedTx (..)
    , ErrNoSuchWallet (..)
    , ErrSignTx (..)
    , ErrSubmitTx (..)
    , ErrWalletAlreadyExists (..)
    , NewWallet (..)
    , WalletLayer
    )
import Cardano.Wallet.Api
    ( Addresses, Api, Transactions, Wallets )
import Cardano.Wallet.Api.Types
    ( ApiAddress (..)
    , ApiCoins (..)
    , ApiT (..)
    , ApiTransaction
    , ApiWallet (..)
    , PostTransactionData
    , WalletBalance (..)
    , WalletPostData (..)
    , WalletPutData (..)
    , WalletPutPassphraseData (..)
    , getApiMnemonicT
    )
import Cardano.Wallet.CoinSelection
    ( CoinSelectionOptions (..) )
import Cardano.Wallet.Primitive.AddressDiscovery
    ( SeqState (..), defaultAddressPoolGap )
import Cardano.Wallet.Primitive.Model
    ( availableBalance, getState, totalBalance )
import Cardano.Wallet.Primitive.Types
    ( AddressState, Coin (..), TxOut (..), WalletId )
import Control.Monad.Catch
    ( throwM )
import Control.Monad.IO.Class
    ( liftIO )
import Control.Monad.Trans.Except
    ( ExceptT, withExceptT )
import Data.Generics.Internal.VL.Lens
    ( (^.) )
import Data.Generics.Labels
    ()
import Data.Quantity
    ( Quantity (..) )
import Servant
    ( (:<|>) (..)
    , NoContent (..)
    , Server
    , err403
    , err404
    , err409
    , err410
    , err500
    , err501
    )
import Servant.Server
    ( Handler (..), ServantErr (..) )

import qualified Cardano.Wallet as W


-- | A Servant server for our wallet API
server :: WalletLayer SeqState -> Server Api
server w =
    addresses w :<|> wallets w :<|> transactions w

{-------------------------------------------------------------------------------
                                    Wallets
-------------------------------------------------------------------------------}

wallets :: WalletLayer SeqState -> Server Wallets
wallets w =
    deleteWallet w
    :<|> getWallet w
    :<|> listWallets w
    :<|> postWallet w
    :<|> putWallet w
    :<|> putWalletPassphrase w

deleteWallet
    :: WalletLayer SeqState
    -> ApiT WalletId
    -> Handler NoContent
deleteWallet w (ApiT wid) = do
    liftHandler $ W.removeWallet w wid
    return NoContent

getWallet
    :: WalletLayer SeqState
    -> ApiT WalletId
    -> Handler ApiWallet
getWallet w (ApiT wid) = do
    (wallet, meta) <- liftHandler $ W.readWallet w wid
    return ApiWallet
        { id =
            ApiT wid
        , addressPoolGap =
            ApiT $ getState wallet ^. #externalPool . #gap
        , balance = ApiT $ WalletBalance
            { available =
                Quantity $ availableBalance wallet
            , total =
                Quantity $ totalBalance wallet
            }
        , delegation =
            ApiT $ ApiT <$> meta ^. #delegation
        , name =
            ApiT $ meta ^. #name
        , passphrase =
            ApiT $ meta ^. #passphraseInfo
        , state =
            ApiT $ meta ^. #status
        }

listWallets
    :: WalletLayer SeqState
    -> Handler [ApiWallet]
listWallets w = do
    wids <- liftIO $ W.listWallets w
    mapM (getWallet w) (ApiT <$> wids)

postWallet
    :: WalletLayer SeqState
    -> WalletPostData
    -> Handler ApiWallet
postWallet w req = do
    wid <- liftHandler $ W.createWallet w $ NewWallet
        { seed =
            getApiMnemonicT (req ^. #mnemonicSentence)
        , secondFactor =
            maybe mempty getApiMnemonicT (req ^. #mnemonicSecondFactor)
        , name =
            getApiT (req ^. #name)
        , passphrase =
            getApiT (req ^. #passphrase)
        , gap =
            maybe defaultAddressPoolGap getApiT (req ^.  #addressPoolGap)
        }
    liftHandler $ W.restoreWallet w wid
    getWallet w (ApiT wid)

putWallet
    :: WalletLayer SeqState
    -> ApiT WalletId
    -> WalletPutData
    -> Handler ApiWallet
putWallet _ _ _ =
    throwM err501

putWalletPassphrase
    :: WalletLayer SeqState
    -> ApiT WalletId
    -> WalletPutPassphraseData
    -> Handler NoContent
putWalletPassphrase _ _ _ =
    throwM err501

{-------------------------------------------------------------------------------
                                    Addresses
-------------------------------------------------------------------------------}

addresses :: WalletLayer SeqState -> Server Addresses
addresses = listAddresses

listAddresses
    :: WalletLayer SeqState
    -> ApiT WalletId
    -> Maybe (ApiT AddressState)
    -> Handler [ApiAddress]
listAddresses _ _ _ =
    throwM err501

{-------------------------------------------------------------------------------
                                    Transactions
-------------------------------------------------------------------------------}

transactions :: WalletLayer SeqState -> Server Transactions
transactions = createTransaction

createTransaction
    :: WalletLayer SeqState
    -> ApiT WalletId
    -> PostTransactionData
    -> Handler ApiTransaction
createTransaction w (ApiT wid) body = do
    -- FIXME Compute the options based on the transaction's size / inputs
    let opts = CoinSelectionOptions { maximumNumberOfInputs = 10 }
    let outs = coerceCoin <$> (body ^. #targets)
    let pwd = getApiT $ body ^. #passphrase
    selection <- liftHandler $ W.createUnsignedTx w wid opts outs
    signedTx <- liftHandler $ W.signTx w wid pwd selection
    liftHandler $ W.submitTx w signedTx
    return undefined
  where
    coerceCoin :: ApiCoins -> TxOut
    coerceCoin (ApiCoins (ApiT addr) (Quantity c)) =
        TxOut addr (Coin $ fromIntegral c)

{-------------------------------------------------------------------------------
                                Error Handling
-------------------------------------------------------------------------------}

-- | Lift our wallet layer into servant 'Handler', by mapping each error to a
-- corresponding servant error.
class LiftHandler e where
    liftHandler :: ExceptT e IO a -> Handler a
    liftHandler action = Handler (withExceptT handler action)
    handler :: e -> ServantErr

-- FIXME
--
-- For now, just "dumb" mapping from our internal errors to servant errors.
-- In practice, we want to create nice error messages giving as much details as
-- we can.

instance LiftHandler ErrNoSuchWallet where
    handler = \case
        ErrNoSuchWallet _ -> err404

instance LiftHandler ErrWalletAlreadyExists where
    handler = \case
        ErrWalletAlreadyExists _ -> err409

instance LiftHandler ErrCreateUnsignedTx where
    handler = \case
        ErrCreateUnsignedTxNoSuchWallet _ -> err404
        ErrCreateUnsignedTxCoinSelection _ -> err403

instance LiftHandler ErrSignTx where
    handler = \case
        ErrSignTx _ -> err500
        ErrSignTxNoSuchWallet _ -> err410
        ErrSignTxWrongPassphrase _ -> err403

instance LiftHandler ErrSubmitTx where
    handler _ = err500
