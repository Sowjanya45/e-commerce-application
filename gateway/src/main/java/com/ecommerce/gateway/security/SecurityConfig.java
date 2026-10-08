package com.ecommerce.gateway.security;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.core.convert.converter.Converter;
import org.springframework.http.HttpMethod;
import org.springframework.security.authentication.AbstractAuthenticationToken;
import org.springframework.security.config.annotation.web.reactive.EnableWebFluxSecurity;
import org.springframework.security.config.web.server.ServerHttpSecurity;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.server.resource.authentication.ReactiveJwtAuthenticationConverter;
import org.springframework.security.web.server.SecurityWebFilterChain;
import org.springframework.security.web.server.util.matcher.ServerWebExchangeMatcher;
import reactor.core.publisher.Flux;
import reactor.core.publisher.Mono;

import java.net.InetSocketAddress;
import java.util.List;

@Configuration
@EnableWebFluxSecurity
public class SecurityConfig {

    /**
     * Actuator runs on its own management port (see gateway-service-docker.yml),
     * which docker-compose publishes on 127.0.0.1 only. Requests arriving on that
     * port need no JWT so Prometheus can scrape; everything on the public port
     * still goes through the chain below.
     */
    @Bean
    @Order(Ordered.HIGHEST_PRECEDENCE)
    public SecurityWebFilterChain managementSecurityChain(
            ServerHttpSecurity http,
            @Value("${management.server.port:-1}") int managementPort) {
        return http
                .securityMatcher(exchange -> {
                    InetSocketAddress local = exchange.getRequest().getLocalAddress();
                    boolean onManagementPort = managementPort > 0
                            && local != null && local.getPort() == managementPort;
                    return onManagementPort
                            ? ServerWebExchangeMatcher.MatchResult.match()
                            : ServerWebExchangeMatcher.MatchResult.notMatch();
                })
                .csrf(ServerHttpSecurity.CsrfSpec::disable)
                .authorizeExchange(exchange -> exchange.anyExchange().permitAll())
                .build();
    }

    @Bean
    public SecurityWebFilterChain securityWebFilterChain(ServerHttpSecurity http) {
        return http
                .csrf(ServerHttpSecurity.CsrfSpec::disable)
                .authorizeExchange(exchange -> exchange
                        // Browsing (GET) stays open to any authenticated user; only
                        // product management is restricted to accounts holding the
                        // PRODUCT client role (nobody gets this role by default at
                        // registration time - grant it manually in Keycloak for an
                        // admin/seller account).
                        .pathMatchers(HttpMethod.POST, "/api/products/**").hasRole("PRODUCT")
                        .pathMatchers(HttpMethod.PUT, "/api/products/**").hasRole("PRODUCT")
                        .pathMatchers(HttpMethod.DELETE, "/api/products/**").hasRole("PRODUCT")
                        // Stock PATCH endpoints exist only for order-service, which
                        // calls product-service directly (not through the gateway).
                        .pathMatchers(HttpMethod.PATCH, "/api/products/**").denyAll()
                        // Listing every user exposes everyone's personal data.
                        .pathMatchers(HttpMethod.GET, "/api/users").hasRole("ADMIN")
                        .anyExchange().authenticated())
                .oauth2ResourceServer(oauth2 ->
                        oauth2.jwt(jwt ->
                                jwt.jwtAuthenticationConverter(grantedAuthoritiesExtractor())))
                .build();
    }

    private Converter<Jwt, Mono<AbstractAuthenticationToken>> grantedAuthoritiesExtractor() {
        ReactiveJwtAuthenticationConverter jwtAuthenticationConverter =
                new ReactiveJwtAuthenticationConverter();
        jwtAuthenticationConverter.setJwtGrantedAuthoritiesConverter(jwt -> {
            List<String> roles = JwtRoles.of(jwt);

            return Flux.fromIterable(roles)
                    .map(role -> new SimpleGrantedAuthority("ROLE_" + role));

        });
        return jwtAuthenticationConverter;
    }
}
