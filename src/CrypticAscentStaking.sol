// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// Contract for managing a staking game
contract CrypticAscentStaking is ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    // Declaring the game token interface
    IERC20 public immutable gameToken;

    // Constants for the staking requirements and game fee
    uint256 public constant MINIMUM_STAKE = 100 * 10**18; // Minimum stake amount: 100 tokens
    uint256 public constant GAME_FEE_PERCENT = 5; // Game fee percentage: 5%

    // Structure defining the properties of a game
    struct Game {
        uint256 totalStake; // Total staked tokens in the game
        uint256 remainingPlayers; // Players left to join the game
        bool isActive; // Is the game active
        bool isCompleted; // Is the game completed
        mapping(address => bool) players; // Mapping to track players
        mapping(address => uint256) playerStakes; // Mapping to track stakes of players
    }

    // Mapping of game IDs to Game structures
    mapping(uint256 => Game) public games;
    uint256 public nextGameId; // Next game ID to be assigned

    // Event declarations for logging key actions
    event GameCreated(uint256 indexed gameId, uint256 playerCount);
    event PlayerStaked(uint256 indexed gameId, address player, uint256 amount);
    event GameStarted(uint256 indexed gameId, uint256 totalStake);
    event PayoutDistributed(uint256 indexed gameId, address[] winners, uint256[] rewards);
    event GameCompleted(uint256 indexed gameId);
    event AllStakesTransferredToOwner(uint256 indexed gameId, uint256 amount);

    // Constructor to set the game token address and transfer ownership to deployer
    constructor(address _gameToken) Ownable(msg.sender) {
        gameToken = IERC20(_gameToken);
    }

    // Function to create a new game with a specified number of players
    function createGame(uint256 _playerCount) external onlyOwner whenNotPaused returns (uint256) {
        require(_playerCount >= 2, "Minimum 2 players required"); // Ensure minimum player count

        uint256 gameId = nextGameId++; // Assign new game ID and increment
        Game storage game = games[gameId]; // Create a new game instance
        game.remainingPlayers = _playerCount; // Set the player count

        emit GameCreated(gameId, _playerCount); // Log the game creation
        return gameId;
    }

    // Function for players to stake tokens in a specific game
    function stake(uint256 _gameId) external nonReentrant whenNotPaused {
        Game storage game = games[_gameId]; // Retrieve the game instance
        require(!game.isActive, "Game already started"); // Ensure game has not started
        require(game.remainingPlayers > 0, "Game is full"); // Ensure slots are available
        require(!game.players[msg.sender], "Already staked"); // Ensure player has not already staked

        game.players[msg.sender] = true; // Register player
        game.playerStakes[msg.sender] = MINIMUM_STAKE; // Record player stake
        game.totalStake += MINIMUM_STAKE; // Update total stake
        game.remainingPlayers--; // Decrement remaining player count

        gameToken.safeTransferFrom(msg.sender, address(this), MINIMUM_STAKE); // Transfer tokens to contract

        emit PlayerStaked(_gameId, msg.sender, MINIMUM_STAKE); // Log the staking event

        // If no remaining players, activate the game
        if (game.remainingPlayers == 0) {
            game.isActive = true;
            emit GameStarted(_gameId, game.totalStake); // Log the game start
        }
    }

    // Function to distribute rewards to winners based on their scores
    function distributePayouts(uint256 _gameId, address[] memory _winners, uint256[] memory _scores) external onlyOwner nonReentrant whenNotPaused {
        Game storage game = games[_gameId]; // Retrieve the game instance
        require(game.isActive, "Game not active"); // Ensure game is active
        require(!game.isCompleted, "Game already completed"); // Ensure game is not already completed
        require(_winners.length > 0 && _winners.length == _scores.length, "Invalid winners or scores"); // Validate input arrays

        game.isActive = false; // Deactivate game
        game.isCompleted = true; // Mark game as completed
        uint256 totalReward = game.totalStake; // Get total staked tokens
        uint256 gameFee = (totalReward * GAME_FEE_PERCENT) / 100; // Calculate game fee
        totalReward -= gameFee; // Deduct fee from total reward

        uint256 totalScore = 0; // Initialize total score
        for (uint i = 0; i < _scores.length; i++) {
            require(_scores[i] > 0, "Scores must be positive"); // Ensure all scores are positive
            totalScore += _scores[i]; // Sum scores
        }

        require(totalScore > 0, "Total score must be greater than zero"); // Ensure total score is valid

        uint256[] memory rewards = new uint256[](_winners.length); // Initialize rewards array
        for (uint i = 0; i < _winners.length; i++) {
            address winner = _winners[i];
            require(game.players[winner], "Invalid winner"); // Validate winner
            uint256 reward = (totalReward * _scores[i]) / totalScore; // Calculate reward based on score
            gameToken.safeTransfer(winner, reward); // Transfer reward to winner
            rewards[i] = reward; // Record reward
        }

        gameToken.safeTransfer(owner(), gameFee); // Transfer game fee to owner
        emit PayoutDistributed(_gameId, _winners, rewards); // Log the payout distribution
        emit GameCompleted(_gameId); // Log game completion
    }

    // Function to transfer all staked tokens to the owner if no winner is declared
    function transferStakesToOwner(uint256 _gameId) external onlyOwner nonReentrant whenNotPaused {
        Game storage game = games[_gameId]; // Retrieve the game instance
        require(game.isActive, "Game not active"); // Ensure game is active
        require(!game.isCompleted, "Game already completed"); // Ensure game is not already completed

        game.isActive = false; // Deactivate game
        game.isCompleted = true; // Mark game as completed
        uint256 totalReward = game.totalStake; // Get total staked tokens
        gameToken.safeTransfer(owner(), totalReward); // Transfer total stakes to owner

        emit AllStakesTransferredToOwner(_gameId, totalReward); // Log the transfer of stakes
        emit GameCompleted(_gameId); // Log game completion
    }

    // Function to retrieve information about a specific game
    function getGameInfo(uint256 _gameId) external view returns (uint256 totalStake, uint256 remainingPlayers, bool isActive, bool isCompleted) {
        Game storage game = games[_gameId]; // Retrieve the game instance
        return (game.totalStake, game.remainingPlayers, game.isActive, game.isCompleted); // Return game details
    }

    // Function to check if a player is part of a specific game
    function isPlayerInGame(uint256 _gameId, address _player) external view returns (bool) {
        return games[_gameId].players[_player]; // Return player participation status
    }

    // Function to pause the contract, restricting certain actions
    function pause() external onlyOwner {
        _pause();
    }

    // Function to unpause the contract, allowing restricted actions
    function unpause() external onlyOwner {
        _unpause();
    }

    // Function to allow the owner to withdraw a specified amount of tokens
    function withdrawToken(IERC20 _token, address _to, uint256 _amount) external onlyOwner {
        require(_to != address(0), "Invalid address"); // Ensure valid recipient address
        _token.safeTransfer(_to, _amount); // Transfer tokens to recipient
    }
}
