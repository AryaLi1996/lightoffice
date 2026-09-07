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
        // Intranet portal the desktop client connects to by default.
        defaultPortal: 'http://10.0.7.10:8080',
        // ONLYOFFICE Document Server backing real-time co-editing.
        documentServer: 'http://10.0.7.20',
        // Providers reachable from the corporate network. Public SaaS
        // providers are dropped so the client cannot be pointed off-network.
        allowedProviders: ['lightoffice', 'nextcloud', 'owncloud']
    };

    global.LIGHTOFFICE_CLOUD = DEFAULTS;
})(typeof window !== 'undefined' ? window : this);
