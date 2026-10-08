package com.ecommerce.gateway.security;

import org.springframework.security.oauth2.jwt.Jwt;

import java.util.Collections;
import java.util.List;
import java.util.Map;

/** Reads the app's client roles out of a Keycloak access token. */
final class JwtRoles {

    private static final String CLIENT_ID = "oauth2-pkce";

    private JwtRoles() {
    }

    /**
     * Client roles from {@code resource_access.oauth2-pkce.roles}; empty (never
     * null) when the token carries no roles, so such a token is simply
     * unauthorised instead of failing with a server error.
     */
    @SuppressWarnings("unchecked")
    static List<String> of(Jwt jwt) {
        Map<String, Object> resourceAccess = jwt.getClaimAsMap("resource_access");
        if (resourceAccess == null) {
            return Collections.emptyList();
        }
        Object client = resourceAccess.get(CLIENT_ID);
        if (!(client instanceof Map<?, ?> clientMap)) {
            return Collections.emptyList();
        }
        Object roles = ((Map<String, Object>) clientMap).get("roles");
        return roles instanceof List<?> list ? (List<String>) list : Collections.emptyList();
    }
}
