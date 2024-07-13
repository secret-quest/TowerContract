// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/CrypticAscentStaking.sol";
import "../src/MockERC20.sol";

/// @title CrypticAscentStakingTest
/// @notice Test contract for CrypticAscentStaking
contract CrypticAscentStakingTest is Test {
    CrypticAscentStaking public staking;
    MockERC20 public mockToken;

    address public owner;
    address public player1;
    address public player2;
    address public player3;

    uint256 public constant INITIAL_BALANCE = 1000 * 10**18;
    uint256 public constant MIN_STAKE = 100 * 10**18;

    /// @notice Set up the testing environment before each test
    function setUp() public {
        // Deploy the mock token and staking contract
        mockToken = new MockERC20();
        staking = new CrypticAscentStaking(address(mockToken));

        // Set up addresses
        owner = address(this);
        player1 = address(0x1);
        player2 = address(0x2);
        player3 = address(0x3);

        // Mint initial tokens to players
        mockToken.mint(player1, INITIAL_BALANCE);
        mockToken.mint(player2, INITIAL_BALANCE);
        mockToken.mint(player3, INITIAL_BALANCE);

        // Approve staking contract to spend tokens on behalf of players
        vm.prank(player1);
        mockToken.approve(address(staking), type(uint256).max);
        vm.prank(player2);
        mockToken.approve(address(staking), type(uint256).max);
        vm.prank(player3);
        mockToken.approve(address(staking), type(uint256).max);
    }

    /// @notice Test creating a new game
    function testCreateGame() public {
        uint256 gameId = staking.createGame(3);
        (uint256 totalStake, uint256 remainingPlayers, bool isActive, bool isCompleted, uint256 creationTime) = staking.getGameInfo(gameId);
        
        assertEq(totalStake, 0, "Total stake should be 0 for a new game");
        assertEq(remainingPlayers, 3, "Remaining players should be 3");
        assertFalse(isActive, "New game should not be active");
        assertFalse(isCompleted, "New game should not be completed");
        assertEq(creationTime, block.timestamp, "Creation time should be current block timestamp");
    }

    /// @notice Test staking in a game
    function testStake() public {
        uint256 gameId = staking.createGame(3);

        vm.prank(player1);
        staking.stake(gameId);

        (uint256 totalStake, uint256 remainingPlayers, bool isActive, bool isCompleted, ) = staking.getGameInfo(gameId);
        
        assertEq(totalStake, MIN_STAKE, "Total stake should be equal to minimum stake");
        assertEq(remainingPlayers, 2, "Remaining players should decrease by 1");
        assertFalse(isActive, "Game should not be active yet");
        assertFalse(isCompleted, "Game should not be completed");
        assertTrue(staking.isPlayerInGame(gameId, player1), "Player1 should be in the game");
    }

    /// @notice Test pausing and unpausing the contract
    function testPauseUnpause() public {
        staking.pause();
        assertTrue(staking.paused(), "Contract should be paused");

        vm.expectRevert("Pausable: paused");
        staking.createGame(2);

        staking.unpause();
        assertFalse(staking.paused(), "Contract should be unpaused");

        uint256 gameId = staking.createGame(2);
        assertEq(gameId, 0, "Should be able to create a game after unpausing");
    }

    /// @notice Test game activation when all players have staked
    function testGameActivation() public {
        uint256 gameId = staking.createGame(2);

        vm.prank(player1);
        staking.stake(gameId);

        vm.prank(player2);
        staking.stake(gameId);

        (uint256 totalStake, uint256 remainingPlayers, bool isActive, bool isCompleted, ) = staking.getGameInfo(gameId);
        
        assertEq(totalStake, 2 * MIN_STAKE, "Total stake should be double the minimum stake");
        assertEq(remainingPlayers, 0, "No remaining players");
        assertTrue(isActive, "Game should be active");
        assertFalse(isCompleted, "Game should not be completed yet");
    }

    /// @notice Test distributing payouts to winners
    function testDistributePayouts() public {
        uint256 gameId = staking.createGame(2);

        vm.prank(player1);
        staking.stake(gameId);

        vm.prank(player2);
        staking.stake(gameId);

        address[] memory winners = new address[](2);
        winners[0] = player1;
        winners[1] = player2;

        uint256[] memory scores = new uint256[](2);
        scores[0] = 60;
        scores[1] = 40;

        uint256 totalStake = 2 * MIN_STAKE;
        uint256 gameFee = (totalStake * staking.GAME_FEE_PERCENT()) / 100;
        uint256 totalReward = totalStake - gameFee;

        uint256 expectedPlayer1Reward = (totalReward * 60) / 100;
        uint256 expectedPlayer2Reward = (totalReward * 40) / 100;

        staking.distributePayouts(gameId, winners, scores);

        assertEq(mockToken.balanceOf(player1), INITIAL_BALANCE - MIN_STAKE + expectedPlayer1Reward, "Incorrect balance for player1 after payout");
        assertEq(mockToken.balanceOf(player2), INITIAL_BALANCE - MIN_STAKE + expectedPlayer2Reward, "Incorrect balance for player2 after payout");
        
    }

    

    /// @notice Test transferring all stakes to the owner
    function testTransferStakesToOwner() public {
        uint256 gameId = staking.createGame(2);

        vm.prank(player1);
        staking.stake(gameId);

        vm.prank(player2);
        staking.stake(gameId);

        uint256 totalStake = 2 * MIN_STAKE;
        uint256 initialOwnerBalance = mockToken.balanceOf(address(this));

        staking.transferStakesToOwner(gameId);

        assertEq(mockToken.balanceOf(address(this)), initialOwnerBalance + totalStake, "Incorrect balance transferred to owner");
        
        (,, bool isActive, bool isCompleted,) = staking.getGameInfo(gameId);
        assertFalse(isActive, "Game should not be active after transfer");
        assertTrue(isCompleted, "Game should be completed after transfer");
    }

    /// @notice Test handling of expired games
    function testHandleExpiredGame() public {
        uint256 gameId = staking.createGame(3);

        vm.prank(player1);
        staking.stake(gameId);

        vm.prank(player2);
        staking.stake(gameId);

        uint256 initialPlayer1Balance = mockToken.balanceOf(player1);
        uint256 initialPlayer2Balance = mockToken.balanceOf(player2);

        // Fast forward time to expire the game
        vm.warp(block.timestamp + 8 days);

        staking.handleExpiredGame(gameId);

        assertEq(mockToken.balanceOf(player1), initialPlayer1Balance, "Player1 should have their stake refunded");
        assertEq(mockToken.balanceOf(player2), initialPlayer2Balance, "Player2 should have their stake refunded");

        (,, bool isActive, bool isCompleted,) = staking.getGameInfo(gameId);
        assertFalse(isActive, "Expired game should not be active");
        assertTrue(isCompleted, "Expired game should be marked as completed");
    }

    

    /// @notice Test withdrawing tokens by the owner
    function testWithdrawToken() public {
        uint256 amount = 100 * 10**18;
        mockToken.mint(address(staking), amount);

        uint256 initialBalance = mockToken.balanceOf(address(this));
        staking.withdrawToken(IERC20(address(mockToken)), address(this), amount);

        assertEq(mockToken.balanceOf(address(this)), initialBalance + amount, "Incorrect amount withdrawn");
    }

    

    
}