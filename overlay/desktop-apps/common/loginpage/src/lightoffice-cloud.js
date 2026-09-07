/*
 * LightOffice intranet cloud defaults.
 *
 * Loaded before dialogconnect.js so the "connect to cloud" dialog opens
 * pre-filled with the organisation's own Nextcloud instead of a public host.
 * Keep this in sync with deploy/docker-compose.nextcloud.yml — the address
 * below is the static IP the nextcloud service is pinned to on the
 * lightoffice-intranet bridge (10.0.7.0/24).
 */
(function (global) {
    'use strict';

    var DEFAULTS = {
        // Both addresses point at the SAME host — the collaboration server's
        // own address on the corporate network (the EC2 private IP from
        // deploy/aws/lightoffice-stack.yaml) — on its two published ports.
        // They are deliberately not the containers' bridge addresses: those
        // exist only inside the host and no client can route to them.
        //
        // This value is compiled into the client, so changing the server
        // address means rebuilding and redistributing. Keep it in step with
        // LIGHTOFFICE_PUBLIC_HOST in deploy/.env and with HostPrivateIp in the
        // CloudFormation stack; tests/unit/consistency.test.js fails the build
        // if the three drift apart.
        defaultPortal: 'http://10.0.7.10:8080',
        // ONLYOFFICE Document Server backing real-time co-editing.
        documentServer: 'http://10.0.7.10:8081',
        // Providers reachable from the corporate network. Public SaaS
        // providers are dropped so the client cannot be pointed off-network.
        allowedProviders: ['lightoffice', 'nextcloud', 'owncloud']
    };

    global.LIGHTOFFICE_CLOUD = DEFAULTS;
})(typeof window !== 'undefined' ? window : this);
