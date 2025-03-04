// SPDX-License-Identifier:	AGPL-3.0
pragma solidity ^0.8.10;

import "mgv_src/toy/ERC20BL.sol";

contract TestToken is ERC20BL {
  // Weird behavior encoder
  /// a reference https://github.com/d-xo/weird-erc20
  // Normal: revert on failure, return true on success
  // MissingReturn: revert on failure, returns nothing on success
  // NoRevert: return false on failure, return true on success
  enum MethodResponse {
    Normal,
    MissingReturn,
    NoRevert
  }

  mapping(address => bool) admins;
  uint public __decimals; // full uint to help forge-std's stdstore
  // failSoftly triggers a `return false`, not a revert
  bool _failSoftly = false;
  MethodResponse internal _approveResponse = MethodResponse.Normal;
  MethodResponse internal _transferResponse = MethodResponse.Normal;

  constructor(address admin, string memory name, string memory symbol, uint8 _decimals) ERC20BL(name, symbol) {
    admins[admin] = true;
    __decimals = _decimals;
  }

  function failSoftly(bool toggle) public {
    _failSoftly = toggle;
  }

  function approveResponse(MethodResponse response) external {
    _approveResponse = response;
  }

  function transferResponse(MethodResponse response) external {
    _transferResponse = response;
  }

  function $(uint amount) public view returns (uint) {
    return amount * 10 ** decimals();
  }

  function decimals() public view override returns (uint8) {
    return uint8(__decimals);
  }

  function requireAdmin() internal view {
    require(admins[msg.sender], "TestToken/adminOnly");
  }

  function addAdmin(address admin) external {
    requireAdmin();
    admins[admin] = true;
  }

  function removeAdmin(address admin) external {
    requireAdmin();
    admins[admin] = false;
  }

  function mint(address to, uint amount) external {
    requireAdmin();
    _mint(to, amount);
  }

  function burn(address from, uint amount) external {
    requireAdmin();
    _burn(from, amount);
  }

  function blacklists(address account) external {
    requireAdmin();
    _blacklists(account);
  }

  function whitelists(address account) external {
    requireAdmin();
    _whitelists(account);
  }

  // Vary response according to response enum given
  // Imitates various weird ERC20 tokens
  // cd is the calldata to call yourself with
  function varyResponse(MethodResponse response, bytes memory cd) internal returns (bool) {
    // "fail softly" means just return false, don't revert
    // disregards the case response == MissingReturn
    if (_failSoftly) {
      return false;
    }

    (bool success, bytes memory rd) = address(this).delegatecall(cd);
    if (response == MethodResponse.NoRevert) {
      return (success && abi.decode(rd, (bool)));
    }

    if (!success) {
      assembly {
        revert(add(cd, 32), cd)
      }
    }
    if (response == MethodResponse.MissingReturn) {
      require(abi.decode(rd, (bool)), "TestToken/varyResponse: method returned false");
      assembly ("memory-safe") {
        return(0, 0)
      }
    }

    return abi.decode(rd, (bool));
  }

  // imitate weird transfer methods
  function parentTransfer(address to, uint amount) external returns (bool) {
    return super.transfer(to, amount);
  }

  function transfer(address to, uint amount) public virtual override returns (bool) {
    bytes memory cd = abi.encodeCall(this.parentTransfer, (to, amount));
    return varyResponse(_transferResponse, cd);
  }

  // imitate weird transferFrom methods
  function parentTransferFrom(address from, address to, uint amount) external returns (bool) {
    return super.transferFrom(from, to, amount);
  }

  function transferFrom(address from, address to, uint amount) public virtual override returns (bool) {
    bytes memory cd = abi.encodeCall(this.parentTransferFrom, (from, to, amount));
    return varyResponse(_transferResponse, cd);
  }

  // imitate weird approve methods
  function parentApprove(address spender, uint amount) external returns (bool) {
    return super.approve(spender, amount);
  }

  function approve(address spender, uint amount) public virtual override returns (bool) {
    bytes memory cd = abi.encodeCall(this.parentApprove, (spender, amount));
    return varyResponse(_approveResponse, cd);
  }
}
