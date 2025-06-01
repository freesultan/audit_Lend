// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {OApp, MessagingFee, Origin} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CoreRouter} from "./CoreRouter.sol";

import "./LendStorage.sol";
import "../LToken.sol";
import "../LErc20Delegator.sol";
import "./interaces/LendtrollerInterfaceV2.sol";
import "./interaces/LendInterface.sol";
import "./interaces/UniswapAnchoredViewInterface.sol";
/* @>q 
What happens if cross-chain messages fail or are delayed?
Can liquidations be manipulated through cross-chain timing attacks?

No gas estimation or validation for cross-chain operations. what attacks can be done related to Gas?
*/
/**
 * @title CrossChainRouter
 * @notice Handles all cross-chain lending operations
 * @dev Works with LendStorage for state management and LayerZero for cross-chain messaging
 */
contract CrossChainRouter is OApp, ExponentialNoError {
    //@>i inherits layer0 V2
    using SafeERC20 for IERC20;
    using OptionsBuilder for bytes;

    // Storage contract reference
    LendStorage public immutable lendStorage;
    uint32 public immutable currentEid;

    address public lendtroller;
    address public priceOracle;
    address payable public coreRouter;
    uint256 public constant PROTOCOL_SEIZE_SHARE_MANTISSA = 2.8e16; // 2.8%

    // Struct for LayerZero payload
    struct LZPayload {
        uint256 amount;
        uint256 borrowIndex;
        uint256 collateral;
        address sender;
        address destlToken;
        address liquidator;
        address srcToken;
        uint8 contractType;
    }

    //@>i layerZero message types 
    enum ContractType {
        BorrowCrossChain,//@>i execute borrow on dest chain - critial point = cross-chain validation
        ValidBorrowRequest,
        DestRepay,
        CrossChainLiquidationExecute, //@>i acction seize collateral - critical point = asset seizure
        LiquidationSuccess,
        LiquidationFailure
    }

    // Events
    event CrossChainBorrow(address indexed borrower, address indexed destToken, uint256 amount, uint32 srcEid);
    // Event emitted on successful liquidation
    event LiquidateBorrow(address liquidator, address lToken, address borrower, address lTokenCollateral);
    event LiquidationFailure(address liquidator, address lToken, address borrower, address lTokenCollateral);
    // Event emitted on successful repayment
    event RepaySuccess(address repayBorrowPayer, address lToken, uint256 repayBorrowAccountBorrows);
    event BorrowSuccess(address indexed borrower, address indexed token, uint256 accountBorrow);

    /**
     * @notice Constructor initializes the contract with required addresses
     * @param _endpoint LayerZero endpoint
     * @param _delegate Delegate address
     * @param _lendStorage LendStorage contract address
     * @param _priceOracle PriceOracle contract address
     * @param _lendtroller Lendtroller contract address
     */
    constructor(
        address _endpoint,
        address _delegate,
        address _lendStorage,
        address _priceOracle,
        address _lendtroller,
        address payable _coreRouter,
        uint32 _srcEid
    ) OApp(_endpoint, _delegate) { 
        require(_lendStorage != address(0), "Invalid storage address");

        lendStorage = LendStorage(_lendStorage);

        priceOracle = _priceOracle;
        lendtroller = _lendtroller;
        coreRouter = _coreRouter;
        currentEid = _srcEid;
    }

    receive() external payable {}

    /**
     * ============================================ ADMIN FUNCTIONS ============================================
     */
    function withdrawEth() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");
        //@>q is it ok to let the admin to withdraw all balance? there is no way to withdraw part of it!
        (bool success,) = msg.sender.call{value: balance}("");
        require(success, "ETH transfer failed");
    }

    /**
     * ============================================ USER FUNCTIONS ============================================
     */

    /**
     * @notice Initiates a cross-chain borrow. Initiated on the source chain (Chain A)
     * @param _amount Amount to borrow
     * @param _borrowToken Token to borrow on destination chain
     * @param _destEid Destination chain's layer zero endpoint id
     */
    //@>i the most critical entry point - collateral is on src chain and borrow from dest chain. Borrow initiation > Borrow Confirmation > repayment > Liquidation Execution
    function borrowCrossChain(uint256 _amount, address _borrowToken, uint32 _destEid) external payable {
        require(msg.sender != address(0), "Invalid sender");
        require(_amount != 0, "Zero borrow amount");
        //@>q this check is too generic. why shouldn't check just sufficient amount?
        require(address(this).balance > 0, "Out of money");

        // Get source lToken for collateral
        address _lToken = lendStorage.underlyingTolToken(_borrowToken);
        require(_lToken != address(0), "Unsupported source token");
    
        //@>q what if someone call this unsupported chain? it returns zero and cut in the next check
        // Get the destination chain's version of the token
        address destLToken = lendStorage.underlyingToDestlToken(_borrowToken, _destEid);
        require(destLToken != address(0), "Unsupported destination token");

        // Accrue interest on source token (collateral token) on source chain
        LTokenInterface(_lToken).accrueInterest();

        // Add collateral tracking on source chain
        //@>audit only authorized contracts. Assumes user has supplied collateral but doesn't verify. could borrow without collateral?
        lendStorage.addUserSuppliedAsset(msg.sender, _lToken);

        if (!isMarketEntered(msg.sender, _lToken)) {
            //@>i enter market: register this asset as collateral that can be used to secure loans
            enterMarkets(_lToken); //@>q who is the msg.sender here? crosschain contract? if so , why we enter this contract to use ltoken in markets? 
        }

        
        // Get current collateral amount for the LayerZero message
        // This will be used on dest chain to check if sufficient
        (, uint256 collateral) =
            lendStorage.getHypotheticalAccountLiquidityCollateral(msg.sender, LToken(_lToken), 0, 0);
        //@>q no check for collateral > 0 or collateral >= borrowed amount
        // Send message to destination chain with verified sender
        // borrowIndex of 0 initially - will be set correctly on dest chain
        _send(
            _destEid,
            _amount,
            0, // Initial borrowIndex, will be set on dest chain
            collateral,
            msg.sender,
            destLToken,
            address(0), // liquidator
            _borrowToken,
            ContractType.BorrowCrossChain
        );
        
    }

    function repayCrossChainBorrow(address _borrower, uint256 _amount, address _lToken, uint32 _srcEid) external {
        require(_amount > 0, "Amount must be greater than 0");
        require(_lToken != address(0), "Invalid lToken address");

        // Pass to internal function for processing
        repayCrossChainBorrowInternal(_borrower, msg.sender, _amount, _lToken, _srcEid);
    }

    /**
     * @notice Initiates a cross-chain liquidation. This is called on Chain B (where the debt exists)
     * @param borrower The address of the borrower to liquidate
     * @param repayAmount The amount of the borrowed asset to repay
     * @param srcEid The chain ID where the collateral exists (Chain A)
     * @param lTokenToSeize The collateral token the liquidator will seizes' address on the current chain
     * @param borrowedAsset The borrowed asset address on this chain (Chain B)
     */
    function liquidateCrossChain(
        address borrower,
        uint256 repayAmount,
        uint32 srcEid,
        address lTokenToSeize,
        address borrowedAsset
    ) external {
        LendStorage.LiquidationParams memory params = LendStorage.LiquidationParams({
            borrower: borrower,
            repayAmount: repayAmount,
            srcEid: srcEid,
            lTokenToSeize: lTokenToSeize, // Collateral lToken from the user's position to seize
            borrowedAsset: borrowedAsset,
            storedBorrowIndex: 0,
            borrowPrinciple: 0,
            borrowedlToken: address(0)
        });

        _validateAndPrepareLiquidation(params);
        _executeLiquidation(params);
    }

    /**
     * ============================================ INTERNAL FUNCTIONS ============================================
     */
    //@>i Validate liquidation eligibility

    function _validateAndPrepareLiquidation(LendStorage.LiquidationParams memory params) private view {
        require(params.borrower != msg.sender, "Liquidator cannot be borrower");
        require(params.repayAmount > 0, "Repay amount cannot be zero");

        // Get the lToken for the borrowed asset on this chain
        params.borrowedlToken = lendStorage.underlyingTolToken(params.borrowedAsset);
        require(params.borrowedlToken != address(0), "Invalid borrowed asset");

        // Important: Use underlying token addresses consistently
        address borrowedUnderlying = lendStorage.lTokenToUnderlying(params.borrowedlToken);

        // Verify the borrow position exists and get details
        LendStorage.Borrow[] memory userCrossChainCollaterals =
            lendStorage.getCrossChainCollaterals(params.borrower, borrowedUnderlying);
        bool found = false;

        for (uint256 i = 0; i < userCrossChainCollaterals.length;) {
            if (userCrossChainCollaterals[i].srcEid == params.srcEid) {
                found = true;
                params.storedBorrowIndex = userCrossChainCollaterals[i].borrowIndex;
                params.borrowPrinciple = userCrossChainCollaterals[i].principle;
                break;
            }
            unchecked {
                ++i;
            }
        }
        require(found, "No matching borrow position");

        // Validate liquidation amount against close factor
        uint256 maxLiquidationAmount = lendStorage.getMaxLiquidationRepayAmount(
            params.borrower,
            params.borrowedlToken,
            false // cross-chain liquidation
        );
        require(params.repayAmount <= maxLiquidationAmount, "Exceeds max liquidation");
    }

    function _executeLiquidation(LendStorage.LiquidationParams memory params) private {
        // First part: Validate and prepare liquidation parameters
        uint256 maxLiquidation = _prepareLiquidationValues(params);

        require(params.repayAmount <= maxLiquidation, "Exceeds max liquidation");

        // Secon part: Validate collateral and execute liquidation
        _executeLiquidationCore(params);
    }

    function _prepareLiquidationValues(LendStorage.LiquidationParams memory params)
        private
        returns (uint256 maxLiquidation)
    {
        // Accrue interest
        LTokenInterface(params.borrowedlToken).accrueInterest();
        uint256 currentBorrowIndex = LTokenInterface(params.borrowedlToken).borrowIndex();

        // Calculate current borrow value with accrued interest
        uint256 currentBorrow = (params.borrowPrinciple * currentBorrowIndex) / params.storedBorrowIndex;

        // Verify repay amount is within limits
        maxLiquidation = mul_ScalarTruncate(
            Exp({mantissa: LendtrollerInterfaceV2(lendtroller).closeFactorMantissa()}), currentBorrow
        );

        return maxLiquidation;
    }

    function _executeLiquidationCore(LendStorage.LiquidationParams memory params) private {
        // Calculate seize tokens
        address borrowedlToken = lendStorage.underlyingTolToken(params.borrowedAsset);

        (uint256 amountSeizeError, uint256 seizeTokens) = LendtrollerInterfaceV2(lendtroller)
            .liquidateCalculateSeizeTokens(borrowedlToken, params.lTokenToSeize, params.repayAmount);

        require(amountSeizeError == 0, "Seize calculation failed");
        //@>q can someone do replay attack? there is no specific replay attack protection
        // Send message to Chain A to execute the seize
        _send(
            params.srcEid,
            seizeTokens,
            params.storedBorrowIndex,
            0,
            params.borrower,
            lendStorage.crossChainLTokenMap(params.lTokenToSeize, params.srcEid), // Convert to Chain A version before sending
            msg.sender,
            params.borrowedAsset,
            ContractType.CrossChainLiquidationExecute
        );
    }

    function _updateBorrowPositionForLiquidation(
        LendStorage.LiquidationParams memory params,
        uint256 currentBorrowIndex
    ) private {
        LendStorage.Borrow[] memory userBorrows = lendStorage.getCrossChainCollaterals(msg.sender, params.borrowedAsset);

        for (uint256 i = 0; i < userBorrows.length;) {
            if (userBorrows[i].srcEid == params.srcEid) {
                // Reduce the borrow amount
                uint256 borrowAmount = (userBorrows[i].principle * currentBorrowIndex) / userBorrows[i].borrowIndex;
                userBorrows[i].principle = borrowAmount - params.repayAmount;
                userBorrows[i].borrowIndex = currentBorrowIndex;
                lendStorage.updateCrossChainCollateral(msg.sender, params.borrowedAsset, i, userBorrows[i]);
                break;
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Handles the final liquidation execution on Chain A (collateral chain)
     * @param payload The decoded message payload
     */

    //@>i Execute collateral seizure on collateral chain
    function _handleLiquidationExecute(LZPayload memory payload, uint32 srcEid) private {
        // Execute the seize of collateral
        uint256 protocolSeizeShare = mul_(payload.amount, Exp({mantissa: lendStorage.PROTOCOL_SEIZE_SHARE_MANTISSA()}));

        require(protocolSeizeShare < payload.amount, "Invalid protocol share");

        uint256 liquidatorShare = payload.amount - protocolSeizeShare;

        // Update protocol rewards
        lendStorage.updateProtocolReward(
            payload.destlToken, lendStorage.protocolReward(payload.destlToken) + protocolSeizeShare
        );

        // Distribute LEND rewards
        lendStorage.distributeSupplierLend(payload.destlToken, payload.sender); // borrower
        lendStorage.distributeSupplierLend(payload.destlToken, payload.liquidator); // liquidator

        //@>audit  Critical Issue: 1- Could underflow if totalInvestment < payload.amount . 2- No validation that borrower actually has this much collateral
        // Update total investment for borrower
        lendStorage.updateTotalInvestment(
            payload.sender,
            payload.destlToken,
            lendStorage.totalInvestment(payload.sender, payload.destlToken) - payload.amount
        );

        //@>audit No verification that liquidation actually happened on debt chain
        // Update total investment for liquidator
        lendStorage.updateTotalInvestment(
            payload.liquidator,
            payload.destlToken,
            lendStorage.totalInvestment(payload.liquidator, payload.destlToken) + liquidatorShare
        );

        // Clear user supplied asset if total investment is 0
        if (lendStorage.totalInvestment(payload.sender, payload.destlToken) == 0) {
            lendStorage.removeUserSuppliedAsset(payload.sender, payload.destlToken);
        }

        emit LiquidateBorrow(
            payload.liquidator, // liquidator
            payload.srcToken, // borrowed token
            payload.sender, // borrower
            payload.destlToken // collateral token
        );

        _send(
            srcEid,
            payload.amount,
            0,
            0,
            payload.sender,
            payload.destlToken,
            payload.liquidator,
            payload.srcToken,
            ContractType.LiquidationSuccess
        );
    }

    //@>i Internal repayment processing
    function repayCrossChainBorrowInternal(
        address borrower,
        address repayer,
        uint256 _amount,
        address _lToken,
        uint32 _srcEid
    ) internal {
        address _token = lendStorage.lTokenToUnderlying(_lToken);
        LTokenInterface(_lToken).accrueInterest();

        // Get borrow details and validate
        (uint256 borrowedAmount, uint256 index, LendStorage.Borrow memory borrowPosition) =
            _getBorrowDetails(borrower, _token, _lToken, _srcEid);

        // Calculate and validate repay amount
        uint256 repayAmountFinal = _amount == type(uint256).max ? borrowedAmount : _amount;
        require(repayAmountFinal <= borrowedAmount, "Repay amount exceeds borrow");

        // Handle token transfers and repayment
        _handleRepayment(borrower, repayer, _lToken, repayAmountFinal);

        // Update state
        _updateRepaymentState(
            borrower, _token, _lToken, borrowPosition, repayAmountFinal, borrowedAmount, index, _srcEid
        );

        emit RepaySuccess(borrower, _token, repayAmountFinal);
    }

    //@>i  Retrieve and calculate current borrow details
    function _getBorrowDetails(address borrower, address _token, address _lToken, uint32 _srcEid)
        private
        view
        returns (uint256 borrowedAmount, uint256 index, LendStorage.Borrow memory borrowPosition)
    {
        LendStorage.Borrow[] memory userCrossChainCollaterals = lendStorage.getCrossChainCollaterals(borrower, _token);
        bool found;

        for (uint256 i = 0; i < userCrossChainCollaterals.length;) {
            if (userCrossChainCollaterals[i].srcEid == _srcEid) {
                borrowPosition = userCrossChainCollaterals[i];
                index = i;
                found = true;
                borrowedAmount = (borrowPosition.principle * uint256(LTokenInterface(_lToken).borrowIndex()))
                    / uint256(borrowPosition.borrowIndex);
                break;
            }
            unchecked {
                ++i;
            }
        }
        require(found, "No matching borrow position found");
        return (borrowedAmount, index, borrowPosition);
    }

    /// @dev Repayer must've approved the CoreRouter to spend the tokens
    function _handleRepayment(address _borrower, address repayer, address _lToken, uint256 repayAmountFinal) private {
        // Execute the repayment
        CoreRouter(coreRouter).repayCrossChainLiquidation(_borrower, repayer, repayAmountFinal, _lToken);
    }

    /**
     * Checked on chain A (source chain), as that's where the collateral exists.
     */

    //@>i  Verify position is undercollateralized
    function _checkLiquidationValid(LZPayload memory payload) private view returns (bool) {
        //@>q can someone fool this check to seize a victim's asset?
        (uint256 borrowed, uint256 collateral) = lendStorage.getHypotheticalAccountLiquidityCollateral(
            payload.sender, LToken(payable(payload.destlToken)), 0, payload.amount
        );
        return borrowed > collateral;
    }

    /**
     * @dev - Received on Chain A.
     * - Find the borrow position on Chain B to get the correct srcEid
     * - Repay the borrow using the escrowed tokens
     */
    function _handleLiquidationSuccess(LZPayload memory payload) private {
        // Find the borrow position on Chain B to get the correct srcEid
        address underlying = lendStorage.lTokenToUnderlying(payload.destlToken);

        // Find the specific collateral record
        (bool found, uint256 index) = lendStorage.findCrossChainCollateral(
            payload.sender,
            underlying,
            currentEid, // srcEid is current chain
            0, // We don't know destEid yet, but we can match on other fields
            payload.destlToken,
            payload.srcToken
        );

        require(found, "Borrow position not found");

        LendStorage.Borrow[] memory userCollaterals = lendStorage.getCrossChainCollaterals(payload.sender, underlying);
        uint32 srcEid = uint32(userCollaterals[index].srcEid);

        // Now that we know the borrow position and srcEid, we can repay the borrow using the escrowed tokens
        // repayCrossChainBorrowInternal will handle updating state and distributing rewards.
        repayCrossChainBorrowInternal(
            payload.sender, // The borrower
            payload.liquidator, // The liquidator (repayer)
            payload.amount, // Amount to repay
            payload.destlToken, // lToken representing the borrowed asset on this chain
            srcEid // The chain where the collateral (and borrow reference) is tracked
        );
    }

    /**
     * @dev - Received on Chain A.
     * - The tokens are escrowed in this contract, return them back to the liquidator
     * - These tokens are the underlying tokens of payload.destlToken
     */
    function _handleLiquidationFailure(LZPayload memory payload) private {
        address underlying = lendStorage.lTokenToUnderlying(payload.destlToken);

        // Refund the liquidator
        IERC20(underlying).safeTransfer(payload.liquidator, payload.amount);

        emit LiquidationFailure(payload.liquidator, payload.destlToken, payload.sender, underlying);
    }

    /**
     * @dev - Triggered on Chain A.
     * - Sends a message back to chain B to handle the liquidation failure case.
     */
    function _sendLiquidationFailure(LZPayload memory payload, uint32 srcEid) private {
        _send(
            srcEid,
            payload.amount,
            0,
            0,
            payload.sender,
            payload.destlToken,
            payload.liquidator,
            payload.srcToken,
            ContractType.LiquidationFailure
        );
    }

    function _updateRepaymentState(
        address borrower,
        address _token,
        address _lToken,
        LendStorage.Borrow memory borrowPosition,
        uint256 repayAmountFinal,
        uint256 borrowedAmount,
        uint256 index,
        uint32 _srcEid
    ) private {
        uint256 currentBorrowIndex = LTokenInterface(_lToken).borrowIndex();
        LendStorage.Borrow[] memory userCrossChainCollaterals = lendStorage.getCrossChainCollaterals(borrower, _token);

        if (repayAmountFinal == borrowedAmount) {
            lendStorage.removeCrossChainCollateral(borrower, _token, index);
            if (userCrossChainCollaterals.length == 1) {
                lendStorage.removeUserBorrowedAsset(borrower, _lToken);
            }
        } else {
            userCrossChainCollaterals[index].principle = borrowedAmount - repayAmountFinal;
            userCrossChainCollaterals[index].borrowIndex = currentBorrowIndex;
            lendStorage.updateCrossChainCollateral(borrower, _token, index, userCrossChainCollaterals[index]);
        }

        lendStorage.distributeBorrowerLend(_lToken, borrower);

        _send(
            _srcEid,
            repayAmountFinal,
            currentBorrowIndex,
            0,
            borrower,
            _lToken,
            _token,
            borrowPosition.srcToken,
            ContractType.DestRepay
        );
    }

    function _handleDestRepayMessage(LZPayload memory payload, uint32 srcEid) private {
        // Find specific borrow using the new helper
        (bool found, uint256 index) =
            lendStorage.findCrossChainBorrow(payload.sender, payload.srcToken, srcEid, currentEid, payload.destlToken);

        require(found, "No matching borrow found");

        LendStorage.Borrow[] memory userBorrows = lendStorage.getCrossChainBorrows(payload.sender, payload.srcToken);

        // Calculate current borrow with interest
        uint256 currentBorrow = (userBorrows[index].principle * payload.borrowIndex) / userBorrows[index].borrowIndex;

        if (payload.amount >= currentBorrow) {
            // Full repayment
            lendStorage.removeCrossChainBorrow(payload.sender, payload.srcToken, index);
            if (userBorrows.length == 1) {
                lendStorage.removeUserBorrowedAsset(payload.sender, lendStorage.underlyingTolToken(payload.srcToken));
            }
        } else {
            // Partial repayment - update remaining borrow
            userBorrows[index].principle = currentBorrow - payload.amount;
            userBorrows[index].borrowIndex = payload.borrowIndex;

            lendStorage.updateCrossChainBorrow(payload.sender, payload.srcToken, index, userBorrows[index]);
        }

        // Distribute LEND rewards on source chain
        lendStorage.distributeBorrowerLend(lendStorage.underlyingTolToken(payload.srcToken), payload.sender);

        emit RepaySuccess(payload.sender, payload.srcToken, payload.amount);
    }

    /**
     * @notice Handles the borrow request on the destination chain. Received on Chain B
     * @param payload LayerZero payload containing borrow details
     * @param srcEid Source chain ID where collateral exists
     */
    //@>i Execute borrow, updata state, send confirmation
    function _handleBorrowCrossChainRequest(LZPayload memory payload, uint32 srcEid) private {

 
        // Accrue interest on borrowed token on destination chain
        LTokenInterface(payload.destlToken).accrueInterest();

        // Get current borrow index from destination lToken
        uint256 currentBorrowIndex = LTokenInterface(payload.destlToken).borrowIndex();

        // Important: Use the underlying token address
        address destUnderlying = lendStorage.lTokenToUnderlying(payload.destlToken);

        // Check if user has any existing borrows on this chain
        bool found = false;
        uint256 index;
        //@>q why does not check payload.sender is valid?
        LendStorage.Borrow[] memory userCrossChainCollaterals =
            lendStorage.getCrossChainCollaterals(payload.sender, destUnderlying);

        /**
         * Filter collaterals for the given srcEid. Prevents borrowing from
         * multiple collateral sources.
         */
        for (uint256 i = 0; i < userCrossChainCollaterals.length;) {
            if (
                userCrossChainCollaterals[i].srcEid == srcEid
                    && userCrossChainCollaterals[i].srcToken == payload.srcToken
            ) {
                index = i;
                found = true;
                break;
            }
            unchecked {
                ++i;
            }
        }

        // Get existing borrow amount
        (uint256 totalBorrowed,) = lendStorage.getHypotheticalAccountLiquidityCollateral(
            payload.sender, LToken(payable(payload.destlToken)), 0, payload.amount
        );
        //@>i here we check payload.collateral >= totalBorrowed
        //@>audit payload.collateral is from src chain can could be stale.Time gap between collateral calculation on Chain A and validation on Chain B .Attacker could manipulate prices or liquidate collateral in between
        //@>i No oracle price validation between chains
        // Verify the collateral from source chain is sufficient for total borrowed amount
        require(payload.collateral >= totalBorrowed, "Insufficient collateral");

        // Execute the borrow on destination chain
        CoreRouter(coreRouter).borrowForCrossChain(payload.sender, payload.amount, payload.destlToken, destUnderlying);

        /**
         * @dev If existing cross-chain collateral, update it. Otherwise, add new collateral.
         */
        if (found) {
            uint256 newPrincipleWithAmount = (userCrossChainCollaterals[index].principle * currentBorrowIndex)
                / userCrossChainCollaterals[index].borrowIndex;

            userCrossChainCollaterals[index].principle = newPrincipleWithAmount + payload.amount;
            userCrossChainCollaterals[index].borrowIndex = currentBorrowIndex;

            lendStorage.updateCrossChainCollateral(
                payload.sender, destUnderlying, index, userCrossChainCollaterals[index]
            );
        } else {
            lendStorage.addCrossChainCollateral(
                payload.sender,
                destUnderlying,
                LendStorage.Borrow({
                    srcEid: srcEid,
                    destEid: currentEid,
                    principle: payload.amount,
                    borrowIndex: currentBorrowIndex,
                    borrowedlToken: payload.destlToken,
                    srcToken: payload.srcToken
                })
            );
        }

        // Track borrowed asset
        lendStorage.addUserBorrowedAsset(payload.sender, payload.destlToken);

        // Distribute LEND rewards on destination chain
        lendStorage.distributeBorrowerLend(payload.destlToken, payload.sender);

        // Send confirmation back to source chain with updated borrow details
        _send(
            srcEid,
            payload.amount,
            currentBorrowIndex,
            payload.collateral,
            payload.sender,
            payload.destlToken,
            payload.liquidator,
            payload.srcToken,
            ContractType.ValidBorrowRequest
        );
    }

    /**
     * @notice Enters markets in the lendtroller
     */
    function enterMarkets(address _lToken) internal {
        address[] memory lTokens = new address[](1);
        lTokens[0] = _lToken;
        LendtrollerInterfaceV2(lendtroller).enterMarkets(lTokens);
    }

    /**
     * @notice Checks if a market is entered
     */
    function isMarketEntered(address user, address asset) internal view returns (bool) {
        address[] memory suppliedAssets = lendStorage.getUserSuppliedAssets(user);
        for (uint256 i = 0; i < suppliedAssets.length;) {
            if (suppliedAssets[i] == asset) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    /**
     * @notice Handles the valid borrow request on the source chain. Received on the source chain (Chain A)
     * @param payload LayerZero payload
     * @param srcEid Source chain ID
     */
    function _handleValidBorrowRequest(LZPayload memory payload, uint32 srcEid) private {
        // Find the specific borrow record using the new helper
        (bool found, uint256 index) =
            lendStorage.findCrossChainBorrow(payload.sender, payload.srcToken, srcEid, currentEid, payload.destlToken);

        if (found) {
            // Update existing borrow
            LendStorage.Borrow[] memory userBorrows = lendStorage.getCrossChainBorrows(payload.sender, payload.srcToken);
            userBorrows[index].principle = userBorrows[index].principle + payload.amount;
            userBorrows[index].borrowIndex = payload.borrowIndex;

            // Update in storage
            lendStorage.updateCrossChainBorrow(payload.sender, payload.srcToken, index, userBorrows[index]);
        } else {
            // Add new borrow record
            lendStorage.addCrossChainBorrow(
                payload.sender,
                payload.srcToken,
                LendStorage.Borrow(
                    srcEid, currentEid, payload.amount, payload.borrowIndex, payload.destlToken, payload.srcToken
                )
            );
        }

        lendStorage.addUserBorrowedAsset(payload.sender, lendStorage.underlyingTolToken(payload.srcToken));

        // Emit BorrowSuccess event
        emit BorrowSuccess(payload.sender, payload.srcToken, payload.amount);
    }

    /**
     * ============================================ LAYER ZERO FUNCTIONS ============================================
     */

    /**
     * @dev Internal function to handle incoming Ping messages.
     * @param _origin The origin data of the message.
     * @param _payload The payload of the message.
     */
    //@>i Internal function, only callable by LayerZero 
    //@>q why there is no replay protection here? No nonce or unique ID checking - Vulnerable to malicious messages from compromised chains
    function _lzReceive(
        Origin calldata _origin, //@>i origin chain - sender chain
        bytes32, /*_guid*/
        bytes calldata _payload,
        address, /*_executor*/
        bytes calldata /*_extraData*/
    ) internal override {
        //@>audit there is no expiration for cross-chain message. message can delay signigicantly. liquidation validity is checked on chainA(collateral chain) using current market prices in _checkliquidationValid. Delay between initiating liquidation on chainB and verification on chainA may lead to drastic change in market conditions : 1 - allow liquidation when user is no longer undercollateralized 2- prevent ligitimate liquidation if prices move favorably for the borrower
        LZPayload memory payload;


        // Decode individual fields from payload
        (
            payload.amount, 
            payload.borrowIndex,
            payload.collateral,
            payload.sender,
            payload.destlToken,
            payload.liquidator,
            payload.srcToken,
            payload.contractType
        ) = abi.decode(_payload, (uint256, uint256, uint256, address, address, address, address, uint8));

        //@>q why there is no validation for decoded data? no zero,large, and out of bound checks

        uint32 srcEid = _origin.srcEid;

        //@>i this cast will revert if contractType is out of bound
        ContractType cType = ContractType(payload.contractType);

    
        // Handle different message types
        if (cType == ContractType.BorrowCrossChain) {
            _handleBorrowCrossChainRequest(payload, srcEid);
        } else if (cType == ContractType.ValidBorrowRequest) {
            _handleValidBorrowRequest(payload, srcEid);
        } else if (cType == ContractType.DestRepay) {
            _handleDestRepayMessage(payload, srcEid);
        } else if (cType == ContractType.CrossChainLiquidationExecute) {
            //@>q how can someone seize an asset from a victim while he is not undercollatralized?
            if (_checkLiquidationValid(payload)) {
                _handleLiquidationExecute(payload, srcEid);
            } else {
                _sendLiquidationFailure(payload, srcEid);
            }
        } else if (cType == ContractType.LiquidationSuccess) {
            _handleLiquidationSuccess(payload);
        } else if (cType == ContractType.LiquidationFailure) {
            _handleLiquidationFailure(payload);
        } else {
            revert("Invalid contract type");
        }
    }

    /**
     * @dev Internal function to pay the native fee associated with the message.
     * @param _nativeFee The native fee to be paid.
     * @return nativeFee The amount of native currency paid.
     *
     * @dev Overridden to use contract balance instead of msg.value.
     */
    function _payNative(uint256 _nativeFee) internal virtual override returns (uint256 nativeFee) {
        if (address(this).balance < _nativeFee) {
            revert NotEnoughNative(address(this).balance);
        }
        return _nativeFee;
    }

    /**
     * @notice Sends LayerZero message
     */
    function _send(
        uint32 _dstEid,
        uint256 _amount,
        uint256 _borrowIndex,
        uint256 _collateral,
        address _sender,
        address _destlToken,
        address _liquidator,
        address _srcToken,
        ContractType ctype
    ) internal {
        bytes memory payload =
            abi.encode(_amount, _borrowIndex, _collateral, _sender, _destlToken, _liquidator, _srcToken, ctype);

        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(1_000_000, 0);
         //@>i 
        _lzSend(_dstEid, payload, options, MessagingFee(address(this).balance, 0), payable(address(this)));
    }
}
