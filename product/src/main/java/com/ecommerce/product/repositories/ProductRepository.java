package com.ecommerce.product.repositories;

import com.ecommerce.product.models.Product;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.stereotype.Repository;

import java.util.List;
import java.util.Optional;

@Repository
public interface ProductRepository extends JpaRepository<Product, Long> {
    List<Product> findByActiveTrue();

    @Query("SELECT p FROM products p WHERE p.active = true AND p.stockQuantity > 0 AND LOWER(p.name) LIKE LOWER(CONCAT('%', :keyword, '%'))")
    List<Product> searchProducts(@Param("keyword") String keyword);

    Optional<Product> findByIdAndActiveTrue(Long id);

    // Atomic, conditional decrement so concurrent orders can't both succeed
    // in taking stock below zero. Returns the number of rows updated (0 or 1).
    @Modifying
    @Query("UPDATE products p SET p.stockQuantity = p.stockQuantity - :quantity " +
            "WHERE p.id = :id AND p.active = true AND p.stockQuantity >= :quantity")
    int decrementStock(@Param("id") Long id, @Param("quantity") Integer quantity);

    // Compensating action for a decrement that needs to be rolled back
    // (e.g. a later item in the same order failed to reserve stock).
    @Modifying
    @Query("UPDATE products p SET p.stockQuantity = p.stockQuantity + :quantity WHERE p.id = :id")
    int incrementStock(@Param("id") Long id, @Param("quantity") Integer quantity);
}
