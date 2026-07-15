# The Paxos Protocol

The Paxos protocol is a consensus algorithm that allows a distributed group of untrusted or unreliable computers to agree on a single data value or state, even if some nodes fail or messages get lost. [1, 2, 3, 4, 5]
In MySQL Group Replication (MGR), Paxos ensures that all database instances agree on the exact order in which transactions should be committed. [6]
------------------------------
## How the Paxos Protocol Works
Paxos breaks the process of making a decision down into two distinct phases using three core roles: Proposers (nodes suggesting a change), Acceptors (nodes voting on the change), and Learners (nodes that just execute the decision). In a database cluster, every node usually plays all three roles. [7, 8, 9, 10, 11]

 [ Proposer ]                [ Acceptors (Quorum) ]
      │                                 │
      ├─────── Phase 1a: Prepare(N) ───▶┤ (Checks if N is highest seen)
      ◀─────── Phase 1b: Promise ───────┤ (Promises to reject lower numbers)
      │                                 │
      ├─────── Phase 2a: Accept(N,V) ──▶┤ (Votes to accept value V)
      ◀─────── Phase 2b: Accepted ──────┤ (Value is officially committed)

## Phase 1: Prepare (Getting the Floor) [12]

   1. Prepare Request: A Proposer assigns a unique, incrementing number (N) to its proposed change and sends a Prepare(N) message to all Acceptors.
   2. Promise: Each Acceptor looks at N. If N is higher than any proposal number it has ever seen before, the Acceptor sends back a Promise. This promise guarantees it will ignore any future proposals with a number lower than N. [13, 14, 15, 16, 17]

## Phase 2: Accept (The Vote) [18, 19, 20]

   1. Accept Request: Once the Proposer receives a Promise from a majority (quorum) of Acceptors, it sends an Accept(N, Value) message to the group, where "Value" is the actual transaction or data change. [21]
   2. Accepted: If the Acceptors haven't promised to ignore N in the meantime, they register the vote and send an Accepted message back. Once a majority accepts it, the value is officially committed and broadcasted to the Learners. [22, 23, 24, 25, 26]

------------------------------
## How Paxos Detects Network Splits (Split-Brain Prevention)
A network split (or network partition) occurs when communication breaks down, cutting a cluster into separate, isolated factions. Without Paxos, both sides might continue writing data independently, permanently corrupting the database. [27, 28, 29]
Paxos prevents this entirely using Strict Quorum Math rather than manual "heartbeat timeouts" or guessing. [30]
## 1. The Power of Majority (N/2 + 1)
Paxos requires a strict mathematical majority to pass both Phase 1 (Promises) and Phase 2 (Accepts). [31, 32, 33]

* For a 3-node cluster, a quorum is 2.
* For a 5-node cluster, a quorum is 3. [34, 35, 36]

## 2. Resolving the Split
Imagine a 5-node cluster (Nodes A, B, C, D, E) split cleanly down the middle by a network failure, creating two isolated islands:

   [Island 1]           [Network Cut]           [Island 2]
  (Node A, Node B)            X             (Node C, Node D, Node E)
   Total: 2 nodes             X              Total: 3 nodes
  🚫 CANNOT REACH QUORUM      X             ✅ HAS QUORUM (3/5)
  (Status: Read-Only/Halted)                (Status: Operates Normally)


* Island 1 (Nodes A & B): A client tries to write a transaction to Node A. Node A sends a Paxos Prepare request. However, it can only get responses from A and B (2 votes). Because 2 is not a majority of 5, the Paxos phase fails. Island 1 automatically detects it is in the minority partition, rejects the write, and shifts into a safe, read-only mode to prevent split-brain. [37, 38, 39]
* Island 2 (Nodes C, D, & E): A client writes to Node C. Node C sends a Prepare request and successfully gets responses from C, D, and E (3 votes). Because 3 satisfies the quorum requirement, the Paxos phase succeeds. Island 2 continues operating normally. [40]

Because it is mathematically impossible to split an odd number of nodes into two separate majorities (e.g., you cannot have two separate groups of 3 in a 5-node cluster), only one side of a network split can ever win a Paxos vote. The minority side immediately realizes it lacks a quorum and safely locks itself down. [41, 42, 43, 44]


[1] [https://cse.engin.umich.edu](https://cse.engin.umich.edu/stories/famous-paxos-distributed-protocol-automatically-determined-safe-and-secure)
[2] [https://algomaster.io](https://algomaster.io/learn/system-design/paxos-algorithm)
[3] [https://medium.com](https://medium.com/@vinodbokare0588/paxos-how-distributed-systems-learn-to-agree-even-when-everything-goes-wrong-f231a98a9d7d)
[4] [https://www.scs.stanford.edu](https://www.scs.stanford.edu/~dm/home/papers/paxos.pdf)
[5] [https://medium.com](https://medium.com/@shivamgor498/%EF%B8%8F-paxos-made-simple-part-1-a-parliament-that-never-forgets-dcd06e7792fd)
[6] [https://oneuptime.com](https://oneuptime.com/blog/post/2026-03-31-mysql-how-mysql-group-replication-consensus-works/view)
[7] [https://en.wikipedia.org](https://en.wikipedia.org/wiki/Paxos_%28computer_science%29)
[8] [https://www.mydistributed.systems](https://www.mydistributed.systems/2021/04/paxos.html)
[9] [https://blog.acolyer.org](https://blog.acolyer.org/2015/03/04/paxos-made-simple/)
[10] [https://medium.com](https://medium.com/@razkevich8/distributed-consensus-explained-from-paxos-theory-to-real-world-systems-2836a578eefc)
[11] [https://pdos.csail.mit.edu](https://pdos.csail.mit.edu/archive/6.824-2012/labs/lab-6.html)
[12] [https://medium.com](https://medium.com/@gurpreet.singh_89/exploring-key-distributed-system-algorithms-and-concepts-series-6-two-phase-commit-2pc-and-d868b52f60f3)
[13] [https://en.wikipedia.org](https://en.wikipedia.org/wiki/Paxos_%28computer_science%29)
[14] [https://arpitbhayani.me](https://arpitbhayani.me/blogs/multi-paxos/)
[15] [https://medium.com](https://medium.com/@shivanimutke2501/day-30-system-design-concept-paxos-made-simple-379dfbfaf807)
[16] [https://en.wikipedia.org](https://en.wikipedia.org/wiki/Paxos_%28computer_science%29)
[17] [https://medium.com](https://medium.com/@suresh.sk1691/consensus-in-distributed-systems-363a5a379eb0)
[18] [https://blog.devgenius.io](https://blog.devgenius.io/paxos-algorithm-explained-a3cc147af20)
[19] [https://matklad.github.io](https://matklad.github.io/2022/10/03/from-paxos-to-bft.html)
[20] [https://bowtiedtechguy.medium.com](https://bowtiedtechguy.medium.com/demystifying-paxos-python-implementation-and-visualization-6958c63c8d4b)
[21] [https://medium.com](https://medium.com/@mani.saksham12/raft-and-paxos-consensus-algorithms-for-distributed-systems-138cd7c2d35a)
[22] [https://medium.com](https://medium.com/@suresh.sk1691/consensus-in-distributed-systems-363a5a379eb0)
[23] [https://en.wikipedia.org](https://en.wikipedia.org/wiki/Paxos_%28computer_science%29)
[24] [https://www.the-paper-trail.org](https://www.the-paper-trail.org/post/2009-02-03-consensus-protocols-paxos/)
[25] [https://arpitbhayani.me](https://arpitbhayani.me/blogs/multi-paxos/)
[26] [https://www.mydistributed.systems](https://www.mydistributed.systems/2021/04/paxos.html)
[27] [https://www.linkedin.com](https://www.linkedin.com/posts/mostafa-basati-21a885154_oracle-rac-performancetuning-activity-7367165039889330176-bery)
[28] [https://docs.hazelcast.com](https://docs.hazelcast.com/hazelcast/5.6/network-partitioning/network-partitioning)
[29] [https://medium.com](https://medium.com/@amiteshbharti/pacelc-theorem-explained-a-comprehensive-guide-to-distributed-system-trade-offs-0f2a0748f3ba)
[30] [https://sre.google](https://sre.google/sre-book/managing-critical-state/)
[31] [https://www.mydistributed.systems](https://www.mydistributed.systems/2021/04/paxos.html)
[32] [https://paulcavallaro.com](https://paulcavallaro.com/blog/flexible-paxos/)
[33] [https://medium.com](https://medium.com/@saliktariq/building-consensus-in-distributed-systems-the-power-of-paxos-and-raft-algorithms-f5d7c7da8365)
[34] [https://gauravsarma1992.medium.com](https://gauravsarma1992.medium.com/how-split-brain-happens-in-distributed-databases-and-how-it-gets-fixed-25179bbc4050)
[35] [https://towardsaws.com](https://towardsaws.com/split-brain-quorum-failover-what-every-kubernetes-admin-must-know-66e4d5211d06)
[36] [https://medium.com](https://medium.com/@shivanimutke2501/day-30-system-design-concept-paxos-made-simple-379dfbfaf807)
[37] [https://www.linkedin.com](https://www.linkedin.com/pulse/communication-protocols-distributed-systems-arthur-sergeyan)
[38] [https://matklad.github.io](https://matklad.github.io/2022/10/03/from-paxos-to-bft.html)
[39] [https://medium.com](https://medium.com/@varshitha.rodda9/paxos-algorithm-consensus-in-a-distributed-world-simplified-7d6b02c25e13)
[40] [https://singhajit.com](https://singhajit.com/distributed-systems/majority-quorum/)
[41] [https://hackernoon.com](https://hackernoon.com/understanding-the-paxos-consensus-algorithm-part-i-how-distributed-systems-reach-consensus)
[42] [https://designgurus.substack.com](https://designgurus.substack.com/p/complete-heartbeat-guide-for-system)
[43] [https://devopscube.com](https://devopscube.com/split-brain-scenarios/)
[44] [https://singhajit.com](https://singhajit.com/distributed-systems/heartbeat/)
