// SPDX-License-Identifier:	BSD-2-Clause

// MangroveOffer.sol

// Copyright (c) 2022 ADDMA. All rights reserved.

// Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

// 1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
pragma solidity ^0.8.10;

import {AccessControlled} from "mgv_src/strategies/utils/AccessControlled.sol";
import {IOfferLogic} from "mgv_src/strategies/interfaces/IOfferLogic.sol";
import {MgvLib, IERC20, MgvStructs} from "mgv_src/MgvLib.sol";
import {IMangrove} from "mgv_src/IMangrove.sol";
import {AbstractRouter} from "mgv_src/strategies/routers/AbstractRouter.sol";
import {TransferLib} from "mgv_src/strategies/utils/TransferLib.sol";

/// @title This contract is the basic building block for Mangrove strats.
/// @notice It contains the mandatory interface expected by Mangrove (`IOfferLogic` is `IMaker`) and enforces additional functions implementations (via `IOfferLogic`).
/// @dev Naming scheme:
/// `f() public`: can be used, as is, in all descendants of `this` contract
/// `_f() internal`: descendant of this contract should provide a public wrapper for this function, with necessary guards.
/// `__f__() virtual internal`: descendant of this contract should override this function to specialize it to the needs of the strat.

abstract contract MangroveOffer is AccessControlled, IOfferLogic {
  ///@notice Gas requirement when posting offers via this strategy, excluding router requirement.
  uint public immutable OFFER_GASREQ;
  ///@notice The Mangrove deployment that is allowed to call `this` for trade execution and posthook.
  IMangrove public immutable MGV;
  ///@notice constant for no router
  AbstractRouter public constant NO_ROUTER = AbstractRouter(address(0));
  ///@notice The router to use for this strategy.
  AbstractRouter private __router;

  ///@notice The offer was successfully reposted.
  bytes32 internal constant REPOST_SUCCESS = "offer/updated";
  ///@notice New offer successfully created.
  bytes32 internal constant NEW_OFFER_SUCCESS = "offer/created";
  ///@notice The offer was completely filled.
  bytes32 internal constant COMPLETE_FILL = "offer/filled";

  /**
   * @notice The Mangrove deployment that is allowed to call `this` for trade execution and posthook.
   *   @param mgv The Mangrove deployment.
   */
  event Mgv(IMangrove mgv);

  ///@notice Mandatory function to allow `this` to receive native tokens from Mangrove after a call to `MGV.withdraw(...,deprovision:true)`
  ///@dev override this function if `this` contract needs to handle local accounting of user funds.
  receive() external payable virtual {}

  /**
   * @notice `MangroveOffer`'s constructor
   * @param mgv The Mangrove deployment that is allowed to call `this` for trade execution and posthook.
   * @param gasreq Gas requirement when posting offers via this strategy, excluding router requirement.
   */
  constructor(IMangrove mgv, uint gasreq) AccessControlled(msg.sender) {
    require(uint24(gasreq) == gasreq, "mgvOffer/gasreqOverflow");
    MGV = mgv;
    OFFER_GASREQ = gasreq;
    emit Mgv(mgv);
  }

  /// @inheritdoc IOfferLogic
  function router() public view override returns (AbstractRouter) {
    return __router;
  }

  /// @inheritdoc IOfferLogic
  function offerGasreq() public view returns (uint) {
    AbstractRouter router_ = router();
    if (router_ != NO_ROUTER) {
      return OFFER_GASREQ + router_.routerGasreq();
    } else {
      return OFFER_GASREQ;
    }
  }

  ///*****************************
  /// Mandatory callback functions
  ///*****************************

  ///@notice `makerExecute` is the callback function to execute all offers that were posted on Mangrove by `this` contract.
  ///@param order a data structure that recapitulates the taker order and the offer as it was posted on mangrove
  ///@return ret a bytes32 word to pass information (if needed) to the posthook
  ///@dev it may not be overriden although it can be customized using `__lastLook__`, `__put__` and `__get__` hooks.
  /// NB #1: if `makerExecute` reverts, the offer will be considered to be refusing the trade.
  /// NB #2: `makerExecute` may return a `bytes32` word to pass information to posthook w/o using storage reads/writes.
  /// NB #3: Reneging on trade will have the following effects:
  /// * Offer is removed from the Order Book
  /// * Offer bounty will be withdrawn from offer provision and sent to the offer taker. The remaining provision will be credited to the maker account on Mangrove
  function makerExecute(MgvLib.SingleOrder calldata order)
    external
    override
    onlyCaller(address(MGV))
    returns (bytes32 ret)
  {
    // Invoke hook that implements a last look check during execution - it may renege on trade by reverting.
    ret = __lastLook__(order);
    // Invoke hook to put the inbound token, which are brought by the taker, into a specific reserve.
    require(__put__(order.gives, order) == 0, "mgvOffer/abort/putFailed");
    // Invoke hook to fetch the outbound token, which are promised to the taker, from a specific reserve.
    require(__get__(order.wants, order) == 0, "mgvOffer/abort/getFailed");
  }

  /// @notice `makerPosthook` is the callback function that is called by Mangrove *after* the offer execution.
  /// @notice reverting during its execution will not renege on trade. Revert reason (casted to 32 bytes) is then logged by Mangrove in event `PosthookFail`.
  /// @param order a data structure that recapitulates the taker order and the offer as it was posted on mangrove
  /// @param result a data structure that gathers information about trade execution
  /// @dev It cannot be overridden but can be customized via the hooks `__posthookSuccess__` and `__posthookFallback__` (see below).
  function makerPosthook(MgvLib.SingleOrder calldata order, MgvLib.OrderResult calldata result)
    external
    override
    onlyCaller(address(MGV))
  {
    if (result.mgvData == "mgv/tradeSuccess") {
      __posthookSuccess__(order, result.makerData);
    } else {
      // logging what went wrong during `makerExecute`
      emit LogIncident(
        MGV, IERC20(order.outbound_tkn), IERC20(order.inbound_tkn), order.offerId, result.makerData, result.mgvData
        );
      // calling strat specific todos in case of failure
      __posthookFallback__(order, result);
      __handleResidualProvision__(order);
    }
  }

  ///@notice takes care of status for reposting residual offer in case of a partial fill and logging of potential issues.
  ///@param order a recap of the taker order
  ///@param makerData generated during `makerExecute` so as to log it if necessary
  ///@param repostStatus from the posthook that handles residual reposting
  function logRepostStatus(MgvLib.SingleOrder calldata order, bytes32 makerData, bytes32 repostStatus) internal {
    // reposting below density is not considered an incident in order to allow the contract not to check density before posting residual
    if (
      repostStatus == COMPLETE_FILL || repostStatus == REPOST_SUCCESS || repostStatus == "mgv/writeOffer/density/tooLow"
    ) {
      return;
    } else {
      // Offer failed to repost for bad reason, logging the incident
      emit LogIncident(
        MGV, IERC20(order.outbound_tkn), IERC20(order.inbound_tkn), order.offerId, makerData, repostStatus
        );
    }
  }

  /// @inheritdoc IOfferLogic
  function setRouter(AbstractRouter router_) public override onlyAdmin {
    __router = router_;
    emit SetRouter(router_);
  }

  /// @inheritdoc IOfferLogic
  function approve(IERC20 token, address spender, uint amount) public override onlyAdmin returns (bool) {
    return TransferLib.approveToken(token, spender, amount);
  }

  /// @inheritdoc IOfferLogic
  function activate(IERC20[] calldata tokens) external override onlyAdmin {
    for (uint i = 0; i < tokens.length; ++i) {
      __activate__(tokens[i]);
    }
  }

  ///@notice verifies that Mangrove is allowed to pull tokens from this contract.
  ///@inheritdoc IOfferLogic
  function checkList(IERC20[] calldata tokens) external view override {
    for (uint i = 0; i < tokens.length; ++i) {
      __checkList__(tokens[i]);
    }
  }

  ///@notice override conservatively to define strat-specific additional activation steps.
  ///@param token the ERC20 one wishes this contract to trade on.
  ///@custom:hook overrides of this hook should be conservative and call `super.__activate__(token)`
  function __activate__(IERC20 token) internal virtual {
    AbstractRouter router_ = router();
    // all strat require `this` to approve Mangrove for pulling `token` at the end of `makerExecute`
    require(TransferLib.approveToken(token, address(MGV), type(uint).max), "mgvOffer/approveMangrove/Fail");
    if (router_ != NO_ROUTER) {
      // allowing router to pull `token` from this contract (for the `push` function of the router)
      require(TransferLib.approveToken(token, address(router_), type(uint).max), "mgvOffer/approveRouterFail");
      // letting router performs additional necessary approvals (if any)
      // this will only work if `this` is an authorized maker of the router (i.e. `router.bind(address(this))` has been called by router's admin).
      router_.activate(token);
    }
  }

  ///@notice verifies that Mangrove is allowed to pull tokens from this contract and other strat specific verifications.
  ///@param token a token that is traded by this contract
  ///@custom:hook overrides of this hook should be conservative and call `super.__checkList__(token)`
  function __checkList__(IERC20 token) internal view virtual {
    require(token.allowance(address(this), address(MGV)) > 0, "mgvOffer/LogicMustApproveMangrove");
  }

  /// @inheritdoc IOfferLogic
  function withdrawFromMangrove(uint amount, address payable receiver) public onlyAdmin {
    if (amount == type(uint).max) {
      amount = MGV.balanceOf(address(this));
    }
    // the require below is necessary if the `receive()` function is overriden
    require(MGV.withdraw(amount), "mgvOffer/withdrawFail");
    (bool noRevert,) = receiver.call{value: amount}("");
    // if `receiver` is actually not payable
    require(noRevert, "mgvOffer/weiTransferFail");
  }

  ///@notice Hook that implements where the inbound token, which are brought by the Offer Taker, should go during Taker Order's execution.
  ///@param amount of `inbound` tokens that are on `this` contract's balance and still need to be deposited somewhere
  ///@param order is a recall of the taker order that is at the origin of the current trade.
  ///@return missingPut (<=`amount`) is the amount of `inbound` tokens whose deposit location has not been decided (possibly because of a failure) during this function execution
  ///@dev if the last nested call to `__put__` returns a non zero value, trade execution will revert
  ///@custom:hook overrides of this hook should be conservative and call `super.__put__(missing, order)`
  function __put__(uint amount, MgvLib.SingleOrder calldata order) internal virtual returns (uint missingPut);

  ///@notice Hook that implements where the outbound token, which are promised to the taker, should be fetched from, during Taker Order's execution.
  ///@param amount of `outbound` tokens that still needs to be brought to the balance of `this` contract when entering this function
  ///@param order is a recall of the taker order that is at the origin of the current trade.
  ///@return missingGet (<=`amount`), which is the amount of `outbound` tokens still need to be fetched at the end of this function
  ///@dev if the last nested call to `__get__` returns a non zero value, trade execution will revert
  ///@custom:hook overrides of this hook should be conservative and call `super.__get__(missing, order)`
  function __get__(uint amount, MgvLib.SingleOrder calldata order) internal virtual returns (uint missingGet);

  /// @notice Hook that implements a last look check during Taker Order's execution.
  /// @param order is a recall of the taker order that is at the origin of the current trade.
  /// @return data is a message that will be passed to posthook provided `makerExecute` does not revert.
  /// @dev __lastLook__ should revert if trade is to be reneged on. If not, returned `bytes32` are passed to `makerPosthook` in the `makerData` field.
  /// @custom:hook overrides of this hook should be conservative and call `super.__lastLook__(order)`.
  function __lastLook__(MgvLib.SingleOrder calldata order) internal virtual returns (bytes32 data) {
    order; //shh
    data = bytes32(0);
  }

  ///@notice Post-hook that implements fallback behavior when Taker Order's execution failed unexpectedly.
  ///@param order is a recall of the taker order that is at the origin of the current trade.
  ///@param result contains information about trade.
  ///@return data contains verdict and reason about the executed trade.
  ///@dev `result.mgvData` is Mangrove's verdict about trade success
  ///@dev `result.makerData` either contains the first 32 bytes of revert reason if `makerExecute` reverted or the returned `bytes32`.
  /// @custom:hook overrides of this hook should be conservative and call `super.__posthookFallback__(order, result)`
  function __posthookFallback__(MgvLib.SingleOrder calldata order, MgvLib.OrderResult calldata result)
    internal
    virtual
    returns (bytes32 data)
  {
    order;
    result;
    data = bytes32(0);
  }

  ///@notice Given the current taker order that (partially) consumes an offer, this hook is used to declare how much `order.inbound_tkn` the offer wants after it is reposted.
  ///@param order is a recall of the taker order that is being treated.
  ///@return newWants the new volume of `inbound_tkn` the offer will ask for on Mangrove
  ///@dev default is to require the original amount of tokens minus those that have been given by the taker during trade execution.
  function __residualWants__(MgvLib.SingleOrder calldata order) internal virtual returns (uint newWants) {
    newWants = order.offer.wants() - order.gives;
  }

  ///@notice Given the current taker order that (partially) consumes an offer, this hook is used to declare how much `order.outbound_tkn` the offer gives after it is reposted.
  ///@param order is a recall of the taker order that is being treated.
  ///@return newGives the new volume of `outbound_tkn` the offer will give if fully taken.
  ///@dev default is to require the original amount of tokens minus those that have been sent to the taker during trade execution.
  function __residualGives__(MgvLib.SingleOrder calldata order) internal virtual returns (uint newGives) {
    return order.offer.gives() - order.wants;
  }

  ///@notice Hook that defines what needs to be done to the part of an offer provision that was added to the balance of `this` on Mangrove after an offer has failed.
  ///@param order is a recall of the taker order that failed
  function __handleResidualProvision__(MgvLib.SingleOrder calldata order) internal virtual {
    order; // we leave the provision on Mangrove
  }

  ///@notice Post-hook that implements default behavior when Taker Order's execution succeeded.
  ///@param order is a recall of the taker order that is at the origin of the current trade.
  ///@param makerData is the returned value of the `__lastLook__` hook, triggered during trade execution. The special value `"lastLook/retract"` should be treated as an instruction not to repost the offer on the book.
  ///@return data can be:
  /// * `COMPLETE_FILL` when offer was completely filled
  /// * returned data of `_updateOffer` signalling the status of the reposting attempt.
  /// @custom:hook overrides of this hook should be conservative and call `super.__posthookSuccess__(order, maker_data)`
  function __posthookSuccess__(MgvLib.SingleOrder calldata order, bytes32 makerData)
    internal
    virtual
    returns (bytes32 data)
  {
    // now trying to repost residual
    uint new_gives = __residualGives__(order);
    uint new_wants = __residualWants__(order);
    // Density check at each repost would be too gas costly.
    // We only treat the special case of `gives==0` or `wants==0` (total fill).
    // Offer below the density will cause Mangrove to throw so we encapsulate the call to `updateOffer` in order not to revert posthook for posting at dust level.
    if (new_gives == 0 || new_wants == 0) {
      return COMPLETE_FILL;
    }
    data = _updateOffer(
      OfferArgs({
        outbound_tkn: IERC20(order.outbound_tkn),
        inbound_tkn: IERC20(order.inbound_tkn),
        wants: new_wants,
        gives: new_gives,
        gasreq: order.offerDetail.gasreq(),
        gasprice: order.offerDetail.gasprice(),
        pivotId: order.offer.next(), // using next as pivot since this offer is off the book
        noRevert: true,
        fund: 0
      }),
      order.offerId
    );
    // logs if anything went wrong
    logRepostStatus(order, makerData, data);
  }

  ///@notice Updates the offer specified by `offerId` on Mangrove with the parameters in `args`.
  ///@param args A memory struct containing the offer parameters to update.
  ///@param offerId An unsigned integer representing the identifier of the offer to be updated.
  ///@return status a `bytes32` value representing either `REPOST_SUCCESS` if the update is successful, or an error message if an error occurs and `OfferArgs.noRevert` is `true`. If `OfferArgs.noRevert` is `false`, the function reverts with the error message as the reason.
  function _updateOffer(OfferArgs memory args, uint offerId) internal virtual returns (bytes32);

  ///@notice computes the provision that can be redeemed if deprovisioning a certain offer
  ///@param outbound_tkn the outbound token of the offer list
  ///@param inbound_tkn the inbound token of the offer list
  ///@param offerId the id of the offer
  ///@return provision the provision that can be redeemed
  function _provisionOf(IERC20 outbound_tkn, IERC20 inbound_tkn, uint offerId) internal view returns (uint provision) {
    MgvStructs.OfferDetailPacked offerDetail = MGV.offerDetails(address(outbound_tkn), address(inbound_tkn), offerId);
    unchecked {
      provision = offerDetail.gasprice() * 10 ** 9 * (offerDetail.offer_gasbase() + offerDetail.gasreq());
    }
  }
}
