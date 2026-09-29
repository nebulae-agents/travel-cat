# Postcard recovery

Travel Cat reserves persistent postcard slots for each trip. Missed slots remain available across shutdown, sleep, and later trips. Older trips with missing cards receive separate supplemental records at the actual generation time; their original journal and the active trip snapshot are not rewritten.

After three failed automatic image attempts, generation stops. The album offers a manual retry button that authorizes one additional attempt. A failed manual attempt returns to the stopped state. Repeated clicks, restarts, and expired leases retain the one-shot boundary. Manual requests can resume while automatic travel is paused, provided generation is configured.

The album shows planned, queued, generating, ready, and manual-action states. Model calls observe a persistent minimum interval. Corrupt automatic scheduling caches are preserved before reconstruction; unreadable supplemental records stop processing and remain intact for recovery.

Public-version generation remains restricted to the default black cat. Historical tasks are filtered by the originating trip's frozen character before narrative generation or image leasing. Ordinary postcard presentation support is preserved; supplemental image results currently accept no optional presentation manifest.

Tests use temporary repositories, fake model responses, controlled clocks, and generated test images. No paid generation is needed for these checks.
