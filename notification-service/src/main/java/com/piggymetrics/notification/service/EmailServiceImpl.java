package com.piggymetrics.notification.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.piggymetrics.notification.domain.NotificationType;
import com.piggymetrics.notification.domain.Recipient;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.core.env.Environment;
import org.springframework.core.io.ByteArrayResource;
import org.springframework.mail.javamail.MimeMessageHelper;
import org.springframework.stereotype.Service;
import org.springframework.util.StringUtils;
import software.amazon.awssdk.core.SdkBytes;
import software.amazon.awssdk.services.secretsmanager.SecretsManagerClient;
import software.amazon.awssdk.services.secretsmanager.model.GetSecretValueRequest;
import software.amazon.awssdk.services.secretsmanager.model.GetSecretValueResponse;
import software.amazon.awssdk.services.ses.SesClient;
import software.amazon.awssdk.services.ses.model.RawMessage;
import software.amazon.awssdk.services.ses.model.SendRawEmailRequest;

import javax.mail.MessagingException;
import javax.mail.Session;
import javax.mail.internet.MimeMessage;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.text.MessageFormat;
import java.util.Properties;

@Service
public class EmailServiceImpl implements EmailService {

	private final Logger log = LoggerFactory.getLogger(getClass());
	private final SesClient sesClient;
	private final SecretsManagerClient secretsManagerClient;
	private final Environment env;
	private final ObjectMapper objectMapper;

	@Autowired
	public EmailServiceImpl(
			SesClient sesClient,
			SecretsManagerClient secretsManagerClient,
			Environment env,
			ObjectMapper objectMapper) {
		this.sesClient = sesClient;
		this.secretsManagerClient = secretsManagerClient;
		this.env = env;
		this.objectMapper = objectMapper;
	}

	@Override
	public void send(NotificationType type, Recipient recipient, String attachment) throws MessagingException, IOException {

		final String subject = env.getProperty(type.getSubject());
		final String text = MessageFormat.format(env.getProperty(type.getText()), recipient.getAccountName());
		final String fromAddress = resolveFromAddress();

		MimeMessage message = new MimeMessage(Session.getDefaultInstance(new Properties()));
		MimeMessageHelper helper = new MimeMessageHelper(message, true, StandardCharsets.UTF_8.name());
		helper.setFrom(fromAddress);
		helper.setTo(recipient.getEmail());
		helper.setSubject(subject);
		helper.setText(text);

		if (StringUtils.hasLength(attachment)) {
			helper.addAttachment(env.getProperty(type.getAttachment()), new ByteArrayResource(attachment.getBytes(StandardCharsets.UTF_8)));
		}

		ByteArrayOutputStream outputStream = new ByteArrayOutputStream();
		message.writeTo(outputStream);

		RawMessage rawMessage = RawMessage.builder()
				.data(SdkBytes.fromByteArray(outputStream.toByteArray()))
				.build();

		SendRawEmailRequest request = SendRawEmailRequest.builder()
				.rawMessage(rawMessage)
				.build();

		sesClient.sendRawEmail(request);

		log.info("{} email notification has been sent to {}", type, recipient.getEmail());
	}

	private String resolveFromAddress() {
		String secretName = env.getProperty("SECRETS_MANAGER_SECRET_NAME");
		if (StringUtils.hasLength(secretName)) {
			try {
				GetSecretValueResponse secretValue = secretsManagerClient.getSecretValue(
						GetSecretValueRequest.builder().secretId(secretName).build());
				String secretString = secretValue.secretString();
				if (StringUtils.hasLength(secretString)) {
					JsonNode jsonNode = objectMapper.readTree(secretString);
					String fromEmail = jsonNode.path("fromEmail").asText(null);
					if (StringUtils.hasLength(fromEmail)) {
						return fromEmail;
					}
				}
			} catch (Exception ex) {
				log.warn("Unable to resolve fromEmail from Secrets Manager secret {}", secretName, ex);
			}
		}

		return env.getProperty("notification.email.from", "no-reply@localhost");
	}
}