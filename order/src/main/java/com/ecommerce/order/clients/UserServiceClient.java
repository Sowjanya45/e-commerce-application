package com.ecommerce.order.clients;

import com.ecommerce.order.dtos.UserResponse;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.service.annotation.GetExchange;
import org.springframework.web.service.annotation.HttpExchange;

@HttpExchange
public interface UserServiceClient {

    // userId here is the Keycloak subject the Gateway injects into
    // X-User-ID, not the Mongo document id.
    @GetExchange("/api/users/by-keycloak-id/{keycloakId}")
    UserResponse getUserDetails(@PathVariable String keycloakId);
}
