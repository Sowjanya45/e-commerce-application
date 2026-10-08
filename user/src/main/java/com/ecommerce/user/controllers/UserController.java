package com.ecommerce.user.controllers;

import com.ecommerce.user.dto.UserRequest;
import com.ecommerce.user.dto.UserResponse;
import com.ecommerce.user.services.UserService;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.server.ResponseStatusException;

import java.util.List;

@RestController
@RequiredArgsConstructor
@RequestMapping("/api/users")
@Slf4j
public class UserController {

    private final UserService userService;
//    private static Logger logger = LoggerFactory.getLogger(UserController.class);

    @GetMapping
    public ResponseEntity<List<UserResponse>> getAllUsers(){
        return new ResponseEntity<>(userService.fetchAllUsers(),
                                    HttpStatus.OK);
    }

    @GetMapping("/by-keycloak-id/{keycloakId}")
    public ResponseEntity<UserResponse> getUserByKeycloakId(
            @PathVariable String keycloakId,
            @RequestHeader(value = "X-User-ID", required = false) String callerId,
            @RequestHeader(value = "X-User-Roles", required = false) String callerRoles){
        requireSelfOrAdmin(callerId, callerRoles, keycloakId);
        return userService.fetchUserByKeycloakId(keycloakId)
                .map(ResponseEntity::ok)
                .orElseGet(() -> ResponseEntity.notFound().build());
    }

    @GetMapping("/{id}")
    public ResponseEntity<UserResponse> getUser(
            @PathVariable String id,
            @RequestHeader(value = "X-User-ID", required = false) String callerId,
            @RequestHeader(value = "X-User-Roles", required = false) String callerRoles){
        log.info("Request received for user: {}", id);

        return userService.fetchUser(id)
                .map(user -> {
                    requireSelfOrAdmin(callerId, callerRoles, user.getKeyCloakId());
                    return ResponseEntity.ok(user);
                })
                .orElseGet(() -> ResponseEntity.notFound().build());
    }

    @PostMapping
    public ResponseEntity<String> createUser(@RequestBody UserRequest userRequest){
        if (isBlank(userRequest.getUsername()) || isBlank(userRequest.getEmail())
                || isBlank(userRequest.getPassword()) || isBlank(userRequest.getFirstName())
                || isBlank(userRequest.getLastName())) {
            return ResponseEntity.badRequest()
                    .body("username, email, password, firstName and lastName are required");
        }
        userService.addUser(userRequest);
        return ResponseEntity.ok("User added successfully");
    }

    @PutMapping("/{id}")
    public ResponseEntity<String> updateUser(@PathVariable String id,
                                             @RequestBody UserRequest updateUserRequest,
                                             @RequestHeader(value = "X-User-ID", required = false) String callerId,
                                             @RequestHeader(value = "X-User-Roles", required = false) String callerRoles){
        userService.fetchUser(id).ifPresent(user ->
                requireSelfOrAdmin(callerId, callerRoles, user.getKeyCloakId()));
        boolean updated = userService.updateUser(id, updateUserRequest);
        if (updated)
            return ResponseEntity.ok("User updated successfully");
        return ResponseEntity.notFound().build();
    }

    private static boolean isBlank(String value) {
        return value == null || value.isBlank();
    }

    /**
     * The gateway sets X-User-ID / X-User-Roles from the validated JWT. A request
     * without X-User-ID did not come through the gateway (e.g. order-service
     * looking up a customer), so it is an internal call and is allowed.
     */
    private void requireSelfOrAdmin(String callerId, String callerRoles, String targetKeycloakId) {
        if (callerId == null || callerId.isBlank()) {
            return;
        }
        boolean admin = callerRoles != null
                && java.util.Arrays.asList(callerRoles.split(",")).contains("ADMIN");
        if (!admin && !callerId.equals(targetKeycloakId)) {
            throw new ResponseStatusException(HttpStatus.FORBIDDEN, "You can only access your own profile");
        }
    }
}
