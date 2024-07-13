// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title CrypticAscentStaking
/// @notice A contract for managing a staking game with multiple players and reward distribution
contract CrypticAscentStaking is ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    // Immutable state variables
    IERC20 public immutable gameToken;

    // Constants
    uint256 public constant MINIMUM_STAKE = 100 * 10**18; // Minimum stake amount: 100 tokens
    uint256 public constant GAME_FEE_PERCENT = 5; // Game fee percentage: 5%
    uint256 public constant GAME_EXPIRATION_TIME = 7 days;

    // Struct to represent a game, optimized for gas efficiency
    struct Game {
        uint256 totalStake;
        uint256 remainingPlayers;
        uint256 creationTime;
        bool isActive;
        bool isCompleted;
        mapping(address => bool) players;
        mapping(address => uint256) playerStakes;
    }

    // State variables
    mapping(uint256 => Game) public games;
    uint256 public nextGameId;

    // Events
    event GameCreated(uint256 indexed gameId, uint256 playerCount);
    event PlayerStaked(uint256 indexed gameId, address player, uint256 amount);
    event GameStarted(uint256 indexed gameId, uint256 totalStake);
    event PayoutDistributed(uint256 indexed gameId, address[] winners, uint256[] rewards);
    event GameCompleted(uint256 indexed gameId);
    event AllStakesTransferredToOwner(uint256 indexed gameId, uint256 amount);
    event GameExpired(uint256 indexed gameId);

    /// @notice Constructor to initialize the contract with the game token
    /// @param _gameToken Address of the ERC20 token used for staking and rewards
    constructor(address _gameToken) Ownable(msg.sender) {
        require(_gameToken != address(0), "Invalid token address");
        gameToken = IERC20(_gameToken);
    }

    /// @notice Creates a new game with a specified number of players
    /// @param _playerCount Number of players for the game
    /// @return The ID of the newly created game
    function createGame(uint256 _playerCount) external onlyOwner whenNotPaused returns (uint256) {
        require(_playerCount >= 2, "Minimum 2 players required");

        uint256 gameId = nextGameId++;
        Game storage game = games[gameId];
        game.remainingPlayers = _playerCount;
        game.creationTime = block.timestamp;

        emit GameCreated(gameId, _playerCount);
        return gameId;
    }

    /// @notice Allows a player to stake tokens in a specific game
    /// @param _gameId The ID of the game to stake in
    function stake(uint256 _gameId) external nonReentrant whenNotPaused {
        Game storage game = games[_gameId];
        require(!game.isActive && game.remainingPlayers > 0 && !game.players[msg.sender], "Invalid game state or player");
        require(block.timestamp < game.creationTime + GAME_EXPIRATION_TIME, "Game has expired");

        game.players[msg.sender] = true;
        game.playerStakes[msg.sender] = MINIMUM_STAKE;
        game.totalStake += MINIMUM_STAKE;
        
        if (--game.remainingPlayers == 0) {
            game.isActive = true;
            emit GameStarted(_gameId, game.totalStake);
        }

        gameToken.safeTransferFrom(msg.sender, address(this), MINIMUM_STAKE);

        emit PlayerStaked(_gameId, msg.sender, MINIMUM_STAKE);
    }

    function distributePayouts(uint256 _gameId, address[] calldata _winners, uint256[] calldata _scores) external onlyOwner nonReentrant whenNotPaused {
        Game storage game = games[_gameId];
        require(game.isActive && !game.isCompleted, "Game not active or already completed");
        require(_winners.length > 0 && _winners.length == _scores.length, "Invalid winners or scores");

        uint256 totalReward = game.totalStake;
        uint256 gameFee = (totalReward * GAME_FEE_PERCENT) / 100;
        totalReward -= gameFee;

        uint256 totalScore = 0;
        uint256 totalDistributed = 0;
        uint256 length = _winners.length;
        for (uint i = 0; i < length; i++) {
            require(_scores[i] > 0 && game.players[_winners[i]], "Invalid score or winner");
            totalScore += _scores[i];
        }
        require(totalScore > 0, "Total score must be greater than zero");

        uint256[] memory rewards = new uint256[](length);
        for (uint i = 0; i < length; i++) {
            rewards[i] = (totalReward * _scores[i]) / totalScore;
            gameToken.safeTransfer(_winners[i], rewards[i]);
            totalDistributed += rewards[i];
        }

        if (totalDistributed < totalReward) {
            gameToken.safeTransfer(owner(), totalReward - totalDistributed);
        }
        gameToken.safeTransfer(owner(), gameFee);

        game.isActive = false;
        game.isCompleted = true;

        emit PayoutDistributed(_gameId, _winners, rewards);
        emit GameCompleted(_gameId);
    }


    /// @notice Transfers all staked tokens to the owner if no winner is declared
    /// @param _gameId The ID of the game to transfer stakes from
    function transferStakesToOwner(uint256 _gameId) external onlyOwner nonReentrant whenNotPaused {
        Game storage game = games[_gameId];
        require(game.isActive && !game.isCompleted, "Game not active or already completed");

        game.isActive = false;
        game.isCompleted = true;
        uint256 totalReward = game.totalStake;
        gameToken.safeTransfer(owner(), totalReward);

        emit AllStakesTransferredToOwner(_gameId, totalReward);
        emit GameCompleted(_gameId);
    }

    /// @notice Handles expired games by refunding stakes to players
    /// @param _gameId The ID of the expired game to handle
    function handleExpiredGame(uint256 _gameId) external nonReentrant whenNotPaused {
        Game storage game = games[_gameId];
        require(!game.isActive && !game.isCompleted, "Game is active or completed");
        require(block.timestamp >= game.creationTime + GAME_EXPIRATION_TIME, "Game has not expired yet");

        game.isCompleted = true;
        
        // Refund stakes to players
        for (uint i = 0; i < game.remainingPlayers; i++) {
            address player = address(uint160(uint256(keccak256(abi.encodePacked(_gameId, i)))));
            if (game.players[player]) {
                uint256 playerStake = game.playerStakes[player];
                if (playerStake > 0) {
                    gameToken.safeTransfer(player, playerStake);
                }
            }
        }

        emit GameExpired(_gameId);
    }

    /// @notice Retrieves information about a specific game
    /// @param _gameId The ID of the game to get information for
    /// @return totalStake Total staked tokens in the game
    /// @return remainingPlayers Number of players left to join the game
    /// @return isActive Whether the game is active
    /// @return isCompleted Whether the game is completed
    /// @return creationTime Timestamp of game creation
    function getGameInfo(uint256 _gameId) external view returns (uint256 totalStake, uint256 remainingPlayers, bool isActive, bool isCompleted, uint256 creationTime) {
        Game storage game = games[_gameId];
        return (game.totalStake, game.remainingPlayers, game.isActive, game.isCompleted, game.creationTime);
    }

    /// @notice Checks if a player is part of a specific game
    /// @param _gameId The ID of the game to check
    /// @param _player The address of the player to check
    /// @return bool indicating whether the player is in the game
    function isPlayerInGame(uint256 _gameId, address _player) external view returns (bool) {
        return games[_gameId].players[_player];
    }

    /// @notice Pauses the contract
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Allows the owner to withdraw a specified amount of tokens
    /// @param _token The address of the token to withdraw
    /// @param _to The address to send the tokens to
    /// @param _amount The amount of tokens to withdraw
    function withdrawToken(IERC20 _token, address _to, uint256 _amount) external onlyOwner {
        require(_to != address(0), "Invalid address");
        _token.safeTransfer(_to, _amount);
    }
}