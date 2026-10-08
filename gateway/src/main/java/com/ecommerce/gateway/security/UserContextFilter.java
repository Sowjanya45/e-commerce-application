package com.ecommerce.gateway.security;

import org.springframework.cloud.gateway.filter.GatewayFilterChain;
import org.springframework.cloud.gateway.filter.GlobalFilter;
import org.springframework.core.Ordered;
import org.springframework.http.server.reactive.ServerHttpRequest;
import org.springframework.security.core.context.ReactiveSecurityContextHolder;
import org.springframework.security.core.context.SecurityContext;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;

/**
 * Overwrites any client-supplied X-User-ID / X-User-Roles headers with the
 * subject and client roles of the validated JWT before forwarding downstream,
 * so order/user/product can trust them instead of relying on whatever the
 * caller sent.
 */
@Component
public class UserContextFilter implements GlobalFilter, Ordered {

    private static final String USER_ID_HEADER = "X-User-ID";
    private static final String USER_ROLES_HEADER = "X-User-Roles";

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        return ReactiveSecurityContextHolder.getContext()
                .map(SecurityContext::getAuthentication)
                .filter(JwtAuthenticationToken.class::isInstance)
                .cast(JwtAuthenticationToken.class)
                .map(token -> token.getToken())
                .map(jwt -> new String[]{jwt.getSubject(), String.join(",", JwtRoles.of(jwt))})
                .defaultIfEmpty(new String[]{"", ""})
                .flatMap(caller -> {
                    ServerHttpRequest mutatedRequest = exchange.getRequest().mutate()
                            .headers(headers -> {
                                headers.remove(USER_ID_HEADER);
                                headers.remove(USER_ROLES_HEADER);
                                if (!caller[0].isBlank()) {
                                    headers.set(USER_ID_HEADER, caller[0]);
                                    headers.set(USER_ROLES_HEADER, caller[1]);
                                }
                            })
                            .build();
                    return chain.filter(exchange.mutate().request(mutatedRequest).build());
                });
    }

    @Override
    public int getOrder() {
        return -1;
    }
}
