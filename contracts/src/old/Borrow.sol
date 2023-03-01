// SPDX-License-Identifier: GPLv3
pragma solidity 0.8.13;

import "./tokens/ERC4626/vLiquid.sol";
import "./interface/IDIAOracle.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PartialNodeB} from "./lib/ImportantStructs.sol";

contract Borrow {
    LiquidVault immutable liquidV;
    uint128[3] acceptedTenures = [30, 60, 90]; // days

    // pool of borrowers
    PartialNodeB[] bPool;

    constructor() {
        liquidV = new LiquidVault(msg.sender);
    }

    event NewBorrowRequest(address indexed borrower, address indexed liquid, uint256 indexed assets, uint256 tenure);
    event BurntUnstablePosition(address indexed burner, PartialNodeB bnode);

    function createUnstablePosition(
        uint128 choice,
        uint256 collateralIn_,
        uint256 maximumExpectedOutput_,
        uint128 tenure_,
        uint8 interest
    ) public {
        require(tenure_ < 3, "invalid Tenure");
        require(interest <= 15, "Interest rate cannot be more 15%");
        address collateral_ = liquidV.asset()[choice].token;
        // calculte 125% of maximumExpectedOutput in usd
        uint256 assets = getQuoteByExpectedOutput(maximumExpectedOutput_, 1 gwei, choice);
        require(collateralIn_ >= assets, "Minimum collateral threshold not satisfied");
        // deposit into the vault
        bool success = liquidV.deposit(msg.sender, collateralIn_, choice);
        // create new position
        PartialNodeB memory new_ = PartialNodeB({
            borrower: msg.sender,
            collateral: collateral_,
            collateralIn: collateralIn_,
            maximumExpectedOutput: maximumExpectedOutput_,
            tenure: acceptedTenures[tenure_],
            indexOfCollateral: choice,
            maxPayableInterest: interest,
            restricted: false
        });
        // broadcast new position
        success ? bPool.push(new_) : revert("deposit failed");
        emit NewBorrowRequest(msg.sender, collateral_, assets, tenure_);
    }

    function burnUnstablePosition(uint256 partialNodeBIdx) public returns (bool success) {
        // requires only msg.sender == partialNodeL.borrower
        require(
            msg.sender == bPool[partialNodeBIdx].borrower,
            "Borrower: you are not the borrower that created this node, or node does not exist"
        );
        //create temp memory location
        PartialNodeB memory temp = bPool[partialNodeBIdx];
        // delete the partialnode
        _removeUnstableItemFromPool(partialNodeBIdx);
        // transfer liquid from vault to borrower
        success = liquidV.withdraw(msg.sender, temp.collateralIn, msg.sender, temp.indexOfCollateral);
        emit BurntUnstablePosition(msg.sender, temp);
    }

    function getQuoteByExpectedOutput(
        uint256 maximumExpectedOutput_,
        uint256 unit_,
        uint128 choice
    ) public returns (uint256) {
        require(maximumExpectedOutput_ <= 100000000 ether, "cannot take more than 1m ether");
        // calculate 125% of expected output
        uint256 leastOutput = maximumExpectedOutput_ / 4 + maximumExpectedOutput_ + 5;
        // perform dia oracle operation, get latest price of collateral token
        (uint128 latestPrice, ) = IDIAOracleV2(liquidV.asset()[choice].priceOracle).getValue(
            liquidV.asset()[choice].pair
        );
        // ? slither asked me to change order.
        // @follow-up
        // 2. raw * 10 ** collateral token decimals
        uint256 raw = leastOutput * 10 ** IERC20Metadata(liquidV.asset()[choice].token).decimals();
        // 1. raw / 10 ** usd Decimal
        raw = (raw / unit_) / latestPrice;

        return raw;
    }

    function getAllBorrowers() public view returns (PartialNodeB[] memory) {
        return bPool;
    }

    function _removeUnstableItemFromPool(uint256 index) internal {
        require(index < bPool.length, "unable to remove");
        if (bPool.length == 1) {
            delete bPool[index];
        } else {
            bPool[index] = bPool[bPool.length - 1];
            bPool.pop();
        }
    }

    function getLiquidVaultAddress() public view returns (address) {
        return address(liquidV);
    }
}
