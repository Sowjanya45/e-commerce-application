package com.ecommerce.product.dtos;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.PositiveOrZero;
import lombok.Data;

import java.math.BigDecimal;

@Data
public class ProductRequest {
    @NotBlank(message = "name is required")
    private String name;
    private String description;
    @NotNull(message = "price is required")
    @PositiveOrZero(message = "price must not be negative")
    private BigDecimal price;
    @NotNull(message = "stockQuantity is required")
    @PositiveOrZero(message = "stockQuantity must not be negative")
    private Integer stockQuantity;
    private String category;
    private String imageUrl;
}
