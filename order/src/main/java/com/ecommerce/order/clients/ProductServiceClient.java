package com.ecommerce.order.clients;

import com.ecommerce.order.dtos.ProductResponse;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.service.annotation.GetExchange;
import org.springframework.web.service.annotation.HttpExchange;
import org.springframework.web.service.annotation.PatchExchange;

@HttpExchange
public interface ProductServiceClient {

    @GetExchange("/api/products/{id}")
    ProductResponse getProductDetails(@PathVariable String id);

    // Returns null on failure (insufficient stock / not found), mirroring
    // the null-on-4xx convention getProductDetails already relies on.
    @PatchExchange("/api/products/{id}/decrement-stock")
    String decrementStock(@PathVariable String id, @RequestParam Integer quantity);

    @PatchExchange("/api/products/{id}/restore-stock")
    String restoreStock(@PathVariable String id, @RequestParam Integer quantity);
}
