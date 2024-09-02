// SPDX-License-Identifier: MIT
/*
██████╗░██╗░░░░░░█████╗░░█████╗░███╗░░░███╗
██╔══██╗██║░░░░░██╔══██╗██╔══██╗████╗░████║
██████╦╝██║░░░░░██║░░██║██║░░██║██╔████╔██║
██╔══██╗██║░░░░░██║░░██║██║░░██║██║╚██╔╝██║
██████╦╝███████╗╚█████╔╝╚█████╔╝██║░╚═╝░██║
╚═════╝░╚══════╝░╚════╝░░╚════╝░╚═╝░░░░░╚═╝
*/
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FixedPointMathLib as FpMath} from "@solady/utils/FixedPointMathLib.sol";

import {BloomErrors as Errors} from "@bloom-v2/helpers/BloomErrors.sol";

import {BloomPool} from "@bloom-v2/BloomPool.sol";
import {BloomTestSetup} from "../BloomTestSetup.t.sol";
import {IBloomPool} from "@bloom-v2/interfaces/IBloomPool.sol";

contract BloomUnitTest is BloomTestSetup {
    using FpMath for uint256;

    function setUp() public override {
        super.setUp();
    }

    function testDeployment() public {
        BloomPool newPool = new BloomPool(
            address(stable), address(billToken), address(priceFeed), initialLeverage, initialSpread, owner
        );
        assertNotEq(address(newPool), address(0));
        assertEq(newPool.rwaPriceFeed(), address(priceFeed));
    }

    function testSetPriceFeedNonOwner() public {
        /// Expect revert if not owner calls
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        bloomPool.setPriceFeed(address(1));
        assertEq(bloomPool.rwaPriceFeed(), address(priceFeed));
    }

    function testSetPriceFeedSuccess() public {
        vm.startPrank(owner);
        vm.expectEmit(false, false, false, true);
        emit IBloomPool.RwaPriceFeedSet(address(priceFeed));
        bloomPool.setPriceFeed(address(priceFeed));
    }

    function testSetPriceFeedRevert() public {
        vm.startPrank(owner);
        // Revert if price is 0
        priceFeed.setLatestRoundData(0, 0, 0, 0, 0);
        vm.expectRevert(Errors.InvalidPriceFeed.selector);
        bloomPool.setPriceFeed(address(priceFeed));

        // Revert if feed hasnt been updated in a while
        priceFeed.setLatestRoundData(0, 1, 0, 0, 0);
        vm.expectRevert(Errors.OutOfDate.selector);
        bloomPool.setPriceFeed(address(priceFeed));

        // Revert if feed hasnt has the wrong round id
        priceFeed.setLatestRoundData(1, 1, 0, 0, 0);
        vm.expectRevert(Errors.OutOfDate.selector);
        bloomPool.setPriceFeed(address(priceFeed));
    }

    function testInvalidTbyRate() public {
        vm.expectRevert(Errors.InvalidTby.selector);
        bloomPool.getRate(0);
    }

    function testNonRedeemableBorrower() public {
        vm.expectRevert(Errors.TBYNotRedeemable.selector);
        bloomPool.redeemBorrower(0);
    }

    function testNonKycMarketMaker() public {
        vm.expectRevert(Errors.KYCFailed.selector);
        lenders.push(alice);
        bloomPool.swapIn(lenders, 0);
    }

    function testGetRate() public {
        vm.startPrank(owner);
        bloomPool.whitelistMarketMaker(marketMaker, true);
        bloomPool.whitelistBorrower(borrower, true);

        _createLendOrder(alice, 110e6);
        _fillOrder(alice, 110e6);
        lenders.push(alice);
        _swapIn(1e18);

        assertEq(bloomPool.getRate(0), FpMath.WAD);

        // Move time forward & update price feed
        uint256 newRate = 115e8;
        _skipAndUpdatePrice(3 days, newRate, 1);

        uint256 expectedRate = 115e18 * initialSpread / 110e18; // 110e18 is the initial rate
        assertEq(bloomPool.getRate(0), expectedRate);
    }

    function testSwapOutAmount0() public {
        vm.startPrank(owner);
        bloomPool.whitelistMarketMaker(marketMaker, true);
        bloomPool.whitelistBorrower(borrower, true);

        _createLendOrder(alice, 110e6);
        _fillOrder(alice, 110e6);
        lenders.push(alice);
        _swapIn(1e18);

        vm.startPrank(marketMaker);
        vm.expectRevert(Errors.ZeroAmount.selector);
        bloomPool.swapOut(0, 0);
    }

    function testSwapOutNonMaturedTby() public {
        vm.startPrank(owner);
        bloomPool.whitelistMarketMaker(marketMaker, true);
        bloomPool.whitelistBorrower(borrower, true);

        _createLendOrder(alice, 110e6);
        _fillOrder(alice, 110e6);
        lenders.push(alice);
        _swapIn(1e18);

        // Fast forward to just before the TBY matures & update price feed
        _skipAndUpdatePrice(179 days, 112e8, 2);

        vm.startPrank(marketMaker);
        vm.expectRevert(Errors.TBYNotMatured.selector);
        bloomPool.swapOut(0, 110e6);
    }

    function testSwapInAndOut() public {
        vm.startPrank(owner);
        bloomPool.whitelistMarketMaker(marketMaker, true);
        bloomPool.whitelistBorrower(borrower, true);

        _createLendOrder(alice, 110e6);
        uint256 borrowAmount = _fillOrder(alice, 110e6);
        lenders.push(alice);
        uint256 totalStableCollateral = 110e6 + borrowAmount;
        _swapIn(totalStableCollateral);

        assertEq(bloomPool.getRate(0), FpMath.WAD);

        uint256 expectedRwa = (totalStableCollateral * (10 ** (18 - 6))).divWadUp(110e18);

        assertEq(stable.balanceOf(address(bloomPool)), 0);
        assertEq(billToken.balanceOf(address(bloomPool)), expectedRwa);

        IBloomPool.TbyCollateral memory startCollateral = bloomPool.tbyCollateral(0);
        assertEq(startCollateral.rwaAmount, expectedRwa);
        assertEq(startCollateral.assetAmount, 0);

        _skipAndUpdatePrice(180 days, 110e8, 2);
        vm.startPrank(marketMaker);
        stable.approve(address(bloomPool), totalStableCollateral);
        bloomPool.swapOut(0, expectedRwa);

        assertEq(billToken.balanceOf(address(bloomPool)), 0);
        assertEq(stable.balanceOf(address(bloomPool)), totalStableCollateral);
        assertEq(billToken.balanceOf(marketMaker), expectedRwa);

        IBloomPool.TbyCollateral memory endCollateral = bloomPool.tbyCollateral(0);
        assertEq(endCollateral.rwaAmount, 0);
        assertEq(endCollateral.assetAmount, totalStableCollateral);
        assertEq(bloomPool.isTbyRedeemable(0), true);
    }

    function testTokenIdIncrement() public {
        vm.startPrank(owner);
        bloomPool.whitelistMarketMaker(marketMaker, true);
        bloomPool.whitelistBorrower(borrower, true);

        _createLendOrder(alice, 110e6);
        uint256 borrowAmount = _fillOrder(alice, 110e6);
        lenders.push(alice);

        uint256 totalStableCollateral = 110e6 + borrowAmount;
        uint256 swapClip = totalStableCollateral / 4;

        // First 2 clips should mint the same token id
        _swapIn(swapClip);
        assertEq(bloomPool.lastMintedId(), 0);

        _skipAndUpdatePrice(1 days, 110e8, 2);

        _swapIn(swapClip);
        assertEq(bloomPool.lastMintedId(), 0);

        // Next clip should mint a new token id
        _skipAndUpdatePrice(1 days + 30 minutes, 110e8, 3);

        _swapIn(swapClip);
        assertEq(bloomPool.lastMintedId(), 1);

        // Final clip should mint a new token id
        _skipAndUpdatePrice(3 days, 110e8, 4);

        _swapIn(swapClip);
        assertEq(bloomPool.lastMintedId(), 2);

        // Check that 3 different ids are minted
        assertGt(tby.balanceOf(alice, 0), 0);
        assertGt(tby.balanceOf(alice, 1), 0);
        assertGt(tby.balanceOf(alice, 2), 0);
    }
}