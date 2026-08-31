/**
 * GeniePage -- "Perguntar"
 *
 * Embeds the Genie Chat for "Rota do Perfume · Direção".
 * Shows user email and AI disclaimer.
 */

import { GenieChat } from '@databricks/appkit-ui/react';

export function GeniePage() {
  return (
    <div className="space-y-6 w-full max-w-4xl mx-auto">
      {/* Header */}
      <div>
        <h2 className="text-2xl font-bold text-foreground">Perguntar</h2>
        <p className="text-sm text-muted-foreground mt-0.5">
          Perguntas em linguagem natural sobre a fila e os dados da semana.
        </p>
      </div>

      {/* AI disclaimer */}
      <div className="bg-blue-50 border border-blue-200 rounded-lg p-4 flex gap-3">
        <span className="text-2xl" role="img" aria-hidden="true">🤖</span>
        <div>
          <p className="text-sm font-medium text-blue-800">Respostas geradas por IA</p>
          <p className="text-xs text-blue-600 mt-1">
            O Genie responde perguntas sobre os dados usando SQL gerado automaticamente.
            Sempre verifique o SQL gerado antes de usar em decisões.
          </p>
        </div>
      </div>

      {/* Genie Chat */}
      <div className="h-[min(600px,70vh)] border rounded-lg overflow-hidden">
        {/* alias="default" uses the genie-space resource defined in databricks.yml */}
        <GenieChat alias="genie-space" />
      </div>
    </div>
  );
}
