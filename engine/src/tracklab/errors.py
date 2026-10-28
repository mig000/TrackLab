"""Erros do TrackLab: uma base, uma subclasse por área, mensagem em português para o usuário."""

from __future__ import annotations


class TrackLabError(ValueError):
    """Erro esperado, com mensagem que pode ser mostrada ao usuário sem tradução."""


class PackageError(TrackLabError):
    """Pacote de música ausente, ilegível ou de um esquema que este motor não conhece."""


class SongsterrError(TrackLabError):
    """O Songsterr não devolveu o que a importação precisa."""


class MediaError(TrackLabError):
    """Arquivo de mídia recusado: formato, tamanho, duração, canais ou ferramenta ausente."""


class ModelError(MediaError):
    """Pesos de um modelo ausentes, sem rede para baixar ou com hash diferente do esperado."""


class JobError(TrackLabError):
    """Falha de uma tarefa em segundo plano."""


class JobCancelled(JobError):
    """A tarefa parou porque o usuário cancelou; não é uma falha."""

    def __init__(self, message: str = "Cancelada pelo usuário."):
        super().__init__(message)
