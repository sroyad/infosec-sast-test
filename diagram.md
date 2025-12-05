graph TB
    subgraph Orchestrator["Security Triage Orchestrator"]
        A[Workflow Trigger<br/>Manual/Scheduled] --> B[Discover Repos with<br/>CodeQL Alerts]
        B --> C{200+ Production<br/>Repositories}
    end
    
    subgraph Discovery["Repository Discovery"]
        C --> D[Query GitHub API<br/>List all org repos]
        D --> E[Check each repo for<br/>open CodeQL alerts]
        E --> F[Filter repos with<br/>active security alerts]
        F --> G[Output: List of repos<br/>with alert counts]
    end
    
    subgraph ParallelProcessing["Parallel AI Triage Matrix Strategy"]
        G --> H[Matrix Strategy<br/>5 repos in parallel]
        H --> I1[Repo 1<br/>AI Triage]
        H --> I2[Repo 2<br/>AI Triage]
        H --> I3[Repo 3<br/>AI Triage]
        H --> I4[Repo N<br/>AI Triage]
        H --> I5[Repo N+1<br/>AI Triage]
    end
    
    subgraph AITriage["AI Triage Process per Repository"]
        I1 --> J1[Phase 1: Understand Repository<br/>Get codebase context<br/>Identify patterns]
        J1 --> K1[Phase 2: Analyze Alerts<br/>For each CodeQL alert:<br/>- Understand alert context<br/>- Analyze with AI<br/>- Classify severity<br/>- Determine if false positive]
        K1 --> L1[AI Decision:<br/>- True Positive<br/>- False Positive<br/>- Needs Review]
        L1 --> M1{Auto-dismiss<br/>enabled?}
        M1 -->|Yes| N1[Dismiss False Positives<br/>via GitHub API]
        M1 -->|No| O1[Generate Report<br/>for manual review]
        N1 --> P1[Results Summary]
        O1 --> P1
    end
    
    subgraph Results["Results & Reporting"]
        P1 --> Q[Consolidated Results<br/>across all repos]
        Q --> R[Security Dashboard<br/>- Total alerts analyzed<br/>- False positives dismissed<br/>- True positives identified<br/>- Repos needing attention]
    end
    
    subgraph Scale["Scale & Performance"]
        S[200+ Production Repos] --> T[Processed in batches<br/>5 repos parallel]
        T --> U[AI analyzes each alert<br/>with full repo context]
        U --> V[Automated triage<br/>reduces manual effort]
    end
    
    style A fill:#e1f5ff
    style B fill:#fff4e1
    style H fill:#e8f5e9
    style J1 fill:#f3e5f5
    style K1 fill:#fff9c4
    style L1 fill:#ffccbc
    style Q fill:#c8e6c9
    style R fill:#b39ddb
