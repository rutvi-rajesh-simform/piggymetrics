package com.piggymetrics.account.client;

import com.piggymetrics.account.domain.User;
import org.springframework.cloud.openfeign.FeignClient;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;

@FeignClient(
	name = "auth-service",
	url = "${services.auth-service.url:http://auth-service}"
)
public interface AuthServiceClient {

	@PostMapping(value = "/uaa/users", consumes = MediaType.APPLICATION_JSON_VALUE)
	void createUser(@RequestBody User user);

}