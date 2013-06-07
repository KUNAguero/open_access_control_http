HTTP Open Access Control
========================

Implementation of an HTTP based version of 23b's Open Access Control software, with an authorization cache stored on an SD card.

Based on zyphlar's stripped down open-access-control-minimal-http

23b's Open Access Control - http://code.google.com/p/open-access-control/

zyphlar's open-access-control-minimal-http - https://github.com/zyphlar/open-access-control-minimal-http


HTTP Access API
===============

Expected API

Request:
    GET /auth/RESOURCE_NAME/TAG_ID HTTP/1.0

Authorized Response:
    200 OK

Unauthorized Response:
    401 Unauthorized

