// SPDX-License-Identifier: MIT

pragma solidity ^0.8.9;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AutomationCompatibleInterface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "hardhat/console.sol";

error Raffle__Not_Enough_Eth_Sent();
error Raffle__Lottery_Not_Active();
error Raffle__Transfer_Failed();
error Raffle__UpkeepNotNeeded(
    uint256 lotteryState,
    uint256 participants,
    uint256 balance
);

contract Lottery is Ownable, VRFConsumerBaseV2, AutomationCompatibleInterface {
    enum LOTTERY_STATE {
        OPEN,
        CLOSED,
        CALCULATING_WINNER
    }

    /* events */
    event Lottery_Entered(address indexed participant);
    event Winner_Requested(uint256 indexed requestId);
    event Winner_Picked(address indexed winner);

    /* state variables */

    AggregatorV3Interface internal i_ethUsdDataFeed; //0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419 ETH-USD
    address payable[] private s_participants;
    uint256 private s_lastTimeStamp;
    LOTTERY_STATE private s_lotteryState;
    uint256 private immutable i_interval;
    address private s_recentWinner;
    LOTTERY_STATE public lottery_state;
    uint256 private immutable i_usdEntryFee;
    VRFCoordinatorV2Interface private immutable i_COORDINATOR;
    uint256 private counter;
    bytes32 private immutable i_keyHash; //200gwei - 0x8af398995b04c28e9951adb9721ef74c74f93e6a478f39e7e0777be13527e7ef
    uint64 private immutable i_subscriptionId;
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private immutable i_callbackGasLimit; //100000
    uint32 private constant NUM_WORDS = 1;

    constructor(
        uint256 _entryFee,
        address _priceFeedAdd,
        address _coordinator,
        bytes32 _keyHash,
        uint32 _gasLimit,
        uint32 _subscriptionId,
        uint256 _interval
    ) VRFConsumerBaseV2(_coordinator) {
        lottery_state = LOTTERY_STATE.OPEN;
        i_usdEntryFee = _entryFee * 10 ** 18;
        i_keyHash = _keyHash;
        i_COORDINATOR = VRFCoordinatorV2Interface(_coordinator);
        i_ethUsdDataFeed = AggregatorV3Interface(_priceFeedAdd);
        i_callbackGasLimit = _gasLimit;
        i_subscriptionId = _subscriptionId;
        i_interval = _interval;
        s_lastTimeStamp = block.timestamp;
    }

    function getEntryFee() public view returns (uint256) {
        (, int answer, , , ) = i_ethUsdDataFeed.latestRoundData();
        uint256 value = uint256(answer) * 10 ** 10;
        uint256 temp = ((i_usdEntryFee * 10 ** 18) / value);
        return temp;
    }

    //  function endLottery() public onlyOwner {}

    function enterLottery() external payable {
        if (lottery_state != LOTTERY_STATE.OPEN) {
            revert Raffle__Lottery_Not_Active();
        }

        if (msg.value < getEntryFee()) {
            revert Raffle__Not_Enough_Eth_Sent();
        }
        s_participants.push(payable(msg.sender));
        emit Lottery_Entered(msg.sender);
    }

    function performUpkeep(bytes calldata /* performData */) external override {
        (bool isUpkeepNeeded, ) = checkUpkeep("");
        if (!isUpkeepNeeded) {
            revert Raffle__UpkeepNotNeeded(
                uint256(s_lotteryState),
                s_participants.length,
                address(this).balance
            );
        }

        lottery_state = LOTTERY_STATE.CALCULATING_WINNER;
        // Will revert if subscription is not set and funded.
        uint256 requestId = i_COORDINATOR.requestRandomWords(
            i_keyHash,
            i_subscriptionId,
            REQUEST_CONFIRMATIONS,
            i_callbackGasLimit,
            NUM_WORDS
        );

        emit Winner_Requested(requestId);
    }

    function fulfillRandomWords(
        uint256,
        uint256[] memory _randomWords
    ) internal override {
        uint256 randomWinnerIndex = _randomWords[0] % _randomWords.length;
        address payable currentWinner = s_participants[randomWinnerIndex];

        lottery_state = LOTTERY_STATE.OPEN;
        s_participants = new address payable[](0);
        s_lastTimeStamp = block.timestamp;

        (bool success, ) = currentWinner.call{value: address(this).balance}("");

        s_recentWinner = currentWinner;

        if (!success) {
            revert Raffle__Transfer_Failed();
        }
        emit Winner_Picked(s_recentWinner);
    }

    function checkUpkeep(
        bytes memory /* checkData */
    )
        public
        view
        override
        returns (bool upkeepNeeded, bytes memory /* performData */)
    {
        bool isOpen = (LOTTERY_STATE.OPEN == s_lotteryState);
        bool timePassed = (block.timestamp - s_lastTimeStamp) > i_interval;
        bool hasParticipants = s_participants.length > 0;
        bool hasBalance = address(this).balance > 0;

        upkeepNeeded = (isOpen && timePassed && hasParticipants && hasBalance);

        // We don't use the checkData in this example. The checkData is defined when the Upkeep was registered.
    }

    function getRecentWinner() public view returns (address) {
        return s_recentWinner;
    }

    function getLotteryState() public view returns (LOTTERY_STATE) {
        return lottery_state;
    }

    function getNumberOfParticipants() public view returns (uint256) {
        return s_participants.length;
    }
}
