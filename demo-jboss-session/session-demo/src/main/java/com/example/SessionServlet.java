package com.example;

import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.servlet.http.HttpSession;

import java.io.IOException;
import java.io.PrintWriter;
import java.time.Instant;

@WebServlet("/session")
public class SessionServlet extends HttpServlet {

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        HttpSession session = req.getSession(true);

        // Increment visit counter
        Integer counter = (Integer) session.getAttribute("counter");
        if (counter == null) {
            counter = 0;
        }
        counter++;
        session.setAttribute("counter", counter);

        // Record first visit timestamp (set once)
        String firstVisit = (String) session.getAttribute("firstVisit");
        if (firstVisit == null) {
            firstVisit = Instant.now().toString();
            session.setAttribute("firstVisit", firstVisit);
        }

        // Serving node name
        String nodeName = System.getProperty("jboss.node.name", "unknown-node");

        resp.setContentType("text/plain;charset=UTF-8");
        PrintWriter out = resp.getWriter();
        out.println("Session ID  : " + session.getId());
        out.println("Node        : " + nodeName);
        out.println("Counter     : " + counter);
        out.println("First Visit : " + firstVisit);
    }
}
