# Gradient descent basics

_Lecture · 2027-01-15 08:00 · about 00:03:55 · reviewed_

## At a glance

- Gradient descent moves **parameters** a small step downhill on the loss. _(Key concepts)_

## Summary

An **introduction** to gradient descent: the loss landscape, the learning rate, the gradient, stochastic gradient descent, momentum and Adam. Homework is to implement stochastic gradient descent.


## Key concepts

- **Key:** Gradient descent moves **parameters** a small step downhill on the loss.
- The learning rate sets the step size: too large **overshoots**, too small is slow.
- The **gradient** points to steepest increase, so steps go the opposite way; it can reach a local minimum.
- **Stochastic** gradient descent uses a small random batch per step: noisier but faster.

## Explanations and sources

- **gradient descent**
  - Said: The basic method behind training most neural networks.
  - AI understands: Repeatedly adjusting parameters to lower a loss.
  - More: Each update subtracts the gradient times the learning rate from the parameters.
  - Source: [Gradient descent explained](https://example.org/ml/gradient-descent)
- **learning rate**
  - Said: The size of that step is the learning rate.
  - AI understands: How far each update moves the parameters.
  - Source: [Choosing a learning rate](http://example.org/ml/learning-rate)
- **momentum**
  - Said: A running average of past gradients so the updates are smoother.
  - AI understands: Adding past update direction to the current step.
- **Adam** _(unsure: The lecturer was not certain about the bias-correction details.)_
  - Said: Adam also adapts the learning rate for each parameter.
  - AI understands: An optimizer with per-parameter learning rates and momentum.
  - Source: [Adam optimiser paper](https://example.org/ml/adam)

## Questions to study

- **Why does the gradient not always point to the minimum?**
  - AI: It points to the steepest increase and only describes the local slope.
- **What goes wrong with a learning rate that is too large?**
  - AI: The updates overshoot the valley and the loss bounces around.

## AI insights
_Suggestions from the AI, not things that were said._

- AI: Implement the toy dataset exercise with two learning rates and compare the loss curves.

## What the review changed

- Corrected "Atom" to "Adam" in the study notes. — The student asked about the Adam optimiser.

---
> Note: 2 formatted value(s) were kept out of every request. Spoken names aren't caught.

Written by AI from an automatic transcript. Models — classify: Claude haiku, sections: Claude sonnet, review: Claude opus.
