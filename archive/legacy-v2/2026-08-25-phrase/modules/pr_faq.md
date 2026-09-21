---
name: pr_faq
description: "Amazon-style PR/FAQ workflow for project initiation, vague ideas, or new phases. Use this when the user says 'I have an idea' or 'Start a new project'."
intent: ["init", "start", "idea", "phase"]
version: 1.0.0
---

# Module: Amazon Style PR/FAQ (Project Initiation)

## Purpose
This module is activated when the user wants to start a new project, a new phase, or has a vague idea that needs clarification. Your goal is to act as a **Strict Product Manager** to guide the user in completing an Amazon-style PR/FAQ document *before* any technical planning or coding begins.

## Workflow

1.  **Interview Mode**: Do not just ask the user to "fill in the template". Conduct an interview. Ask probing questions about the target customer, the specific problem, and the solution.
2.  **Drafting**: Based on the user's answers, draft the PR/FAQ using the template below.
3.  **Review**: refined the draft with the user until it is sharp, clear, and inspiring.
4.  **Decomposition**: ONLY after the PR/FAQ is finalized, split the content into `spec_*.md` (Requirements) and `plan_*.md` (Milestones/Tasks).

## Template

### Press Release (PR)

**Headline**
> This is the press release headline.

**Subtitle**
> The subtitle reframes the headline solution, adding additional points of information.

**Date**
> The potential date to launch the product or service.

**Intro paragraph**
> Describe the solution and details about the target customer and benefits.

**Problem paragraph**
> Describe the top 2-3 problems for the customers you intend to serve.

**Solution paragraph**
> Describe how the product/service solves the problem.

**Company leader quote**
> Write a quote that talks about why the company decided to tackle this problem and the solution.

**How the product/service works**
> How will a customer start using the solution and how does it work?

**Customer quote**
> Write a quote from an imaginary customer.

**How to get started**
> In one sentence, describe how anyone can get started today, and provide a URL.

### FAQ

> The FAQ – frequently asked questions – is the second page, and formats all content in a series of questions and answers.

**Internal FAQs**
> Questions stakeholders will likely ask (e.g., risks, dependencies, technical challenges, costs).

**Customer FAQs**
> Questions customers will likely ask (e.g., pricing, compatibility, support).

*Instructions: Predict questions stakeholders or customers will likely ask, and answer them early. Doing this highlights the depth of thinking.*