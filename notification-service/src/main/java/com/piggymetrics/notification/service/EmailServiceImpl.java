package com.piggymetrics.notification.service;

import com.piggymetrics.notification.domain.NotificationType;
import com.piggymetrics.notification.domain.Recipient;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.cloud.context.config.annotation.RefreshScope;
import org.springframework.core.env.Environment;
import org.springframework.core.io.ByteArrayResource;
import org.springframework.mail.javamail.JavaMailSender;
import org.springframework.mail.javamail.MimeMessageHelper;
import org.springframework.stereotype.Service;
import org.springframework.util.StringUtils;

import javax.mail.MessagingException;
import javax.mail.internet.InternetAddress;
import javax.mail.internet.MimeMessage;
import java.io.IOException;
import java.text.MessageFormat;

@Service
@RefreshScope
public class EmailServiceImpl implements EmailService {

	private static final String MAIL_FROM_ADDRESS_PROPERTY = "notification.email.from";
	private static final String MAIL_FROM_NAME_PROPERTY = "notification.email.from-name";

	private final Logger log = LoggerFactory.getLogger(getClass());

	@Autowired
	private JavaMailSender mailSender;

	@Autowired
	private Environment env;

	@Override
	public void send(NotificationType type, Recipient recipient, String attachment) throws MessagingException, IOException {

		final String subject = env.getProperty(type.getSubject());
		final String text = MessageFormat.format(env.getProperty(type.getText()), recipient.getAccountName());
		final String fromAddress = env.getProperty(MAIL_FROM_ADDRESS_PROPERTY);
		final String fromName = env.getProperty(MAIL_FROM_NAME_PROPERTY);

		if (!StringUtils.hasText(fromAddress)) {
			throw new IllegalStateException("Missing required mail sender identity property: " + MAIL_FROM_ADDRESS_PROPERTY);
		}

		MimeMessage message = mailSender.createMimeMessage();

		MimeMessageHelper helper = new MimeMessageHelper(message, true);
		helper.setTo(recipient.getEmail());
		helper.setSubject(subject);
		helper.setText(text);
		if (StringUtils.hasText(fromName)) {
			helper.setFrom(new InternetAddress(fromAddress, fromName));
		} else {
			helper.setFrom(fromAddress);
		}

		if (StringUtils.hasLength(attachment)) {
			helper.addAttachment(env.getProperty(type.getAttachment()), new ByteArrayResource(attachment.getBytes()));
		}

		mailSender.send(message);

		log.info("{} email notification has been sent to {} from {}", type, recipient.getEmail(), fromAddress);
	}
}